//! Win32 side: read the foreground window, paste through a delayed-rendered clipboard, put the old one back.

use crate::{clipboard_text, gate, keep, paste_state, Focus, Hint, Keep, Outcome, Paste};
use std::cell::{Cell, RefCell};
use std::io;
use std::time::{Duration, Instant};
use windows::core::w;
use windows::Win32::Foundation::{CloseHandle, GlobalFree, SetLastError, HANDLE, HGLOBAL, HWND, LPARAM, LRESULT, WIN32_ERROR, WPARAM};
use windows::Win32::Graphics::Gdi::{GetEnhMetaFileBits, SetEnhMetaFileBits, HENHMETAFILE};
use windows::Win32::Security::{GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, TokenIntegrityLevel, TOKEN_MANDATORY_LABEL, TOKEN_QUERY};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData, GetClipboardOwner, OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::{CF_ENHMETAFILE, CF_UNICODETEXT};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    MapVirtualKeyW, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, MAPVK_VK_TO_VSC, VIRTUAL_KEY, VK_CONTROL, VK_V,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetForegroundWindow, GetWindowThreadProcessId, MsgWaitForMultipleObjects, PeekMessageW,
    RegisterClassW, HWND_MESSAGE, MSG, PM_REMOVE, QS_SENDMESSAGE, WINDOW_EX_STYLE, WINDOW_STYLE, WM_RENDERALLFORMATS, WM_RENDERFORMAT, WNDCLASSW,
};

const TEXT: u32 = CF_UNICODETEXT.0 as u32;

thread_local! {
    // The promised text, and when the target read it. The window procedure runs on this thread.
    static OFFER: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    static RENDERED: Cell<Option<Instant>> = const { Cell::new(None) };
}

enum Saved {
    Bytes(u32, Vec<u8>),
    Metafile(Vec<u8>),
}

/// The foreground window now. Call it when the dictation starts and pass it to `insert`.
pub fn foreground() -> Option<Focus> {
    let hwnd = unsafe { GetForegroundWindow() };
    let mut pid = 0;
    if hwnd.is_invalid() || unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) } == 0 {
        return None;
    }
    Some(Focus { hwnd: hwnd.0 as isize, pid })
}

/// Pastes `text` if the foreground window is still `start` and can take our keystrokes; otherwise
/// leaves it on the clipboard and says why. It never moves focus. Blocks up to about 1.5 s, pumping
/// this thread's sent messages so the target can read the text. Errors only when the clipboard can't
/// be opened or written.
pub fn insert(text: &str, start: Option<Focus>) -> io::Result<Outcome> {
    let now = foreground();
    let owner = Owner::new()?;
    let ours = integrity(unsafe { GetCurrentProcess() });
    if let Some(hint) = gate(start, now, ours, now.and_then(|f| integrity_of(f.pid))) {
        owner.leave(text)?;
        return Ok(Outcome::OnClipboard(hint));
    }
    let saved = owner.offer(text)?;
    let posted = Instant::now();
    if !send_ctrl_v() {
        owner.leave(text)?;
        return Ok(Outcome::OnClipboard(Hint::NotLanded));
    }
    loop {
        match paste_state(posted, RENDERED.get(), Instant::now()) {
            Paste::Waiting => owner.pump(Instant::now() + Duration::from_millis(10)),
            Paste::Failed => {
                owner.leave(text)?;
                return Ok(Outcome::OnClipboard(Hint::NotLanded));
            }
            Paste::Landed { restore_at } => {
                owner.pump(restore_at);
                return Ok(Outcome::Pasted { restored: owner.restore(&saved) });
            }
        }
    }
}

/// Puts `text` on the clipboard as plain text, kept in clipboard history (the tray's Recent).
pub fn copy(text: &str) -> io::Result<()> {
    Owner::new()?.leave(text)
}

/// A message-only window that owns the clipboard while we use it and answers WM_RENDERFORMAT.
struct Owner(HWND);

/// The clipboard is open until this drops.
struct Open;

impl Drop for Open {
    fn drop(&mut self) {
        let _ = unsafe { CloseClipboard() };
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = unsafe { DestroyWindow(self.0) };
    }
}

impl Owner {
    fn new() -> io::Result<Self> {
        unsafe {
            let instance = GetModuleHandleW(None)?.into();
            let class = w!("shepetal.insert");
            let wc = WNDCLASSW { lpfnWndProc: Some(wndproc), hInstance: instance, lpszClassName: class, ..Default::default() };
            RegisterClassW(&wc); // 0 from the second call on (already registered); CreateWindowExW fails if neither worked
            let hwnd = CreateWindowExW(WINDOW_EX_STYLE(0), class, None, WINDOW_STYLE(0), 0, 0, 0, 0, Some(HWND_MESSAGE), None, Some(instance), None)?;
            Ok(Owner(hwnd))
        }
    }

    fn open(&self) -> io::Result<Open> {
        for _ in 0..20 {
            if unsafe { OpenClipboard(Some(self.0)) }.is_ok() {
                return Ok(Open);
            }
            std::thread::sleep(Duration::from_millis(10)); // another app has it open
        }
        Err(io::Error::other("another app kept the clipboard open"))
    }

    /// Saves the clipboard, then promises `text` in its place, marked so clipboard history skips it.
    fn offer(&self, text: &str) -> io::Result<Vec<Saved>> {
        OFFER.set(clipboard_text(text));
        RENDERED.set(None);
        let _open = self.open()?;
        let saved = save();
        unsafe {
            EmptyClipboard()?;
            // No data = delayed rendering. Success returns null too, so only a set error code fails.
            SetLastError(WIN32_ERROR(0));
            if let Err(e) = SetClipboardData(TEXT, None) {
                if e.code().is_err() {
                    return Err(e.into());
                }
            }
        }
        for marker in [w!("ExcludeClipboardContentFromMonitorProcessing"), w!("CanIncludeInClipboardHistory")] {
            set(unsafe { RegisterClipboardFormatW(marker) }, &0u32.to_le_bytes())?;
        }
        Ok(saved)
    }

    /// Rule 8: plain text for Ctrl+V. Not marked: this one the user wants in their history.
    fn leave(&self, text: &str) -> io::Result<()> {
        let _open = self.open()?;
        unsafe { EmptyClipboard()? };
        set(TEXT, &clipboard_text(text))
    }

    /// Puts the saved clipboard back, unless another app wrote the clipboard since: theirs is newer.
    fn restore(&self, saved: &[Saved]) -> bool {
        let Ok(_open) = self.open() else { return false };
        if unsafe { GetClipboardOwner() }.ok() != Some(self.0) || unsafe { EmptyClipboard() }.is_err() {
            return false;
        }
        let mut ok = true;
        for s in saved {
            ok &= match s {
                Saved::Bytes(format, bytes) => set(*format, bytes).is_ok(),
                Saved::Metafile(bytes) => unsafe {
                    let emf = SetEnhMetaFileBits(bytes);
                    !emf.is_invalid() && SetClipboardData(CF_ENHMETAFILE.0 as u32, Some(HANDLE(emf.0))).is_ok()
                },
            };
        }
        ok
    }

    /// Handles messages sent to this thread (WM_RENDERFORMAT among them) until `until`. Only this
    /// window's posted messages leave the queue, so a caller's WM_QUIT survives.
    fn pump(&self, until: Instant) {
        let mut msg = MSG::default();
        loop {
            unsafe {
                while PeekMessageW(&mut msg, Some(self.0), 0, 0, PM_REMOVE).as_bool() {
                    DispatchMessageW(&msg);
                }
            }
            let left = until.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return;
            }
            unsafe { MsgWaitForMultipleObjects(None, false, left.as_millis().clamp(1, 10) as u32, QS_SENDMESSAGE) };
        }
    }
}

extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        // The target is reading the text (it holds the clipboard open): the paste landed.
        WM_RENDERFORMAT if wp.0 as u32 == TEXT => {
            if OFFER.with_borrow(|t| set(TEXT, t)).is_ok() {
                RENDERED.set(Some(Instant::now()));
            }
            LRESULT(0)
        }
        // Destroyed while the text is still a promise: write it for real so it isn't lost.
        WM_RENDERALLFORMATS => unsafe {
            if OpenClipboard(Some(hwnd)).is_ok() {
                if GetClipboardOwner().ok() == Some(hwnd) {
                    let _ = OFFER.with_borrow(|t| set(TEXT, t));
                }
                let _ = CloseClipboard();
            }
            LRESULT(0)
        },
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

/// Copies every format on the (open) clipboard that can be put back; see `keep`.
fn save() -> Vec<Saved> {
    let mut saved = Vec::new();
    let mut format = 0;
    loop {
        format = unsafe { EnumClipboardFormats(format) };
        if format == 0 {
            return saved;
        }
        match keep(format) {
            Keep::Bytes => saved.extend(global_bytes(format).map(|b| Saved::Bytes(format, b))),
            Keep::Metafile => saved.extend(metafile_bytes(format).map(Saved::Metafile)),
            Keep::Skip => {}
        }
    }
}

fn global_bytes(format: u32) -> Option<Vec<u8>> {
    unsafe {
        let mem = HGLOBAL(GetClipboardData(format).ok()?.0);
        let p = GlobalLock(mem) as *const u8;
        if p.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(p, GlobalSize(mem)).to_vec();
        let _ = GlobalUnlock(mem);
        Some(bytes)
    }
}

fn metafile_bytes(format: u32) -> Option<Vec<u8>> {
    unsafe {
        let emf = HENHMETAFILE(GetClipboardData(format).ok()?.0);
        let mut bytes = vec![0; GetEnhMetaFileBits(emf, None) as usize];
        (!bytes.is_empty() && GetEnhMetaFileBits(emf, Some(&mut bytes)) as usize == bytes.len()).then_some(bytes)
    }
}

/// Hands `bytes` to the clipboard in global memory. Only while the clipboard is open, or in WM_RENDERFORMAT.
fn set(format: u32, bytes: &[u8]) -> io::Result<()> {
    unsafe {
        let mem = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1))?;
        let p = GlobalLock(mem);
        if p.is_null() {
            let _ = GlobalFree(Some(mem));
            return Err(io::Error::last_os_error());
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p.cast(), bytes.len());
        let _ = GlobalUnlock(mem); // reports an error once the lock count is 0, which is the point
        if let Err(e) = SetClipboardData(format, Some(HANDLE(mem.0))) {
            let _ = GlobalFree(Some(mem)); // the clipboard only takes the memory on success
            return Err(e.into());
        }
        Ok(())
    }
}

/// Ctrl+V as four key events. SendInput doesn't report a UIPI drop, which is why `gate` checks first.
/// ponytail: modifiers the user still holds (Alt, Shift, Win) join the chord; release them first if that bites.
fn send_ctrl_v() -> bool {
    let key = |vk: VIRTUAL_KEY, flags: KEYBD_EVENT_FLAGS| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: vk, wScan: unsafe { MapVirtualKeyW(vk.0 as u32, MAPVK_VK_TO_VSC) } as u16, dwFlags: flags, time: 0, dwExtraInfo: 0 },
        },
    };
    let down = KEYBD_EVENT_FLAGS(0);
    let inputs = [key(VK_CONTROL, down), key(VK_V, down), key(VK_V, KEYEVENTF_KEYUP), key(VK_CONTROL, KEYEVENTF_KEYUP)];
    let sent = unsafe { SendInput(&inputs, size_of::<INPUT>() as i32) };
    sent == inputs.len() as u32
}

/// A process's integrity level (mandatory label RID), or None when its token can't be read.
fn integrity(process: HANDLE) -> Option<u32> {
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(process, TOKEN_QUERY, &mut token).ok()?;
        let mut len = 0;
        let _ = GetTokenInformation(token, TokenIntegrityLevel, None, 0, &mut len);
        let mut buf = vec![0u64; (len as usize).div_ceil(8)]; // u64s keep the struct aligned
        let read = GetTokenInformation(token, TokenIntegrityLevel, Some(buf.as_mut_ptr().cast()), len, &mut len);
        let _ = CloseHandle(token);
        read.ok()?;
        let sid = (*buf.as_ptr().cast::<TOKEN_MANDATORY_LABEL>()).Label.Sid;
        let count = (*GetSidSubAuthorityCount(sid)).checked_sub(1)?;
        Some(*GetSidSubAuthority(sid, u32::from(count)))
    }
}

fn integrity_of(pid: u32) -> Option<u32> {
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?;
    let level = integrity(process);
    let _ = unsafe { CloseHandle(process) };
    level
}
