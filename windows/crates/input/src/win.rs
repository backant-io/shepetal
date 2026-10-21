//! Win32: one thread owns the keyboard hook, the 🤫 overlay and the tray icon, and runs their
//! message loop. The hook passes every key on, except the Space of the hands-free chord while
//! recording (see `Chord::swallow`), so typing is never swallowed.

use crate::*;
use std::cell::RefCell;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{channel, sync_channel, Receiver, Sender};
use std::time::{Duration, Instant};
use windows::core::{w, Error, Result, HSTRING, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::DirectWrite::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Com::{CoInitializeEx, COINIT_APARTMENTTHREADED};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::*;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;

const CLASS: PCWSTR = w!("ShepetalInput");
const WM_CMD: u32 = WM_APP; // a command waits in the channel
const WM_TRAY: u32 = WM_APP + 1; // tray icon callback
const TIMER_ANIM: usize = 1;
const TIMER_WATCH: usize = 2;
const ANIM_MS: u32 = 40;
const WATCH_MS: u32 = 1000;
const ID_OPEN: usize = 1;
const ID_PAUSE: usize = 2;
const ID_COFFEE: usize = 3;
const ID_SPONSORS: usize = 4;
const ID_QUIT: usize = 5;
const ID_LOGIN: usize = 6;
/// Recordings submenu: item `i` of `recordings_menu` is `ID_RECORDINGS + i`.
const ID_RECORDINGS: usize = 7;
/// Recent submenu: transcript `n` is `ID_RECENT + n`.
const ID_RECENT: usize = 100;
/// Hotkey submenu: `HOTKEYS[n]` is `ID_HOTKEY + n`.
const ID_HOTKEY: usize = 200;

static TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);
/// The last mode set was Recording or HandsFree. Set on the caller's thread so the hook sees it
/// before the overlay redraws.
// ponytail: one per process, like the hook; move into Ui if spawn ever runs twice.
static RECORDING: AtomicBool = AtomicBool::new(false);

enum Cmd {
    Mode(Mode),
    Hint(String, u64),
    StartAtLogin(bool),
    DeleteAfter24h(bool),
    Recent(Vec<String>),
    Hotkey(Hotkey, String),
    Quit,
}

/// Handle to the input thread. Cheap to clone; calls from any thread.
#[derive(Clone)]
pub struct Ui {
    tx: Sender<Cmd>,
    hwnd: isize,
}

impl Ui {
    pub fn set_mode(&self, mode: Mode) {
        let on = matches!(mode, Mode::Recording | Mode::HandsFree);
        RECORDING.store(on, Ordering::Relaxed);
        self.send(Cmd::Mode(mode));
    }

    /// Text next to 🤫 for `dur` (product rule 2 uses `HINT_MS`).
    pub fn show_hint(&self, text: &str, dur: Duration) {
        self.send(Cmd::Hint(text.to_string(), dur.as_millis() as u64));
    }

    /// Removes the tray icon, the overlay and the hook, and ends the thread. Call it before the
    /// process exits, or the tray keeps a dead icon until the mouse passes over it.
    /// Sets the check mark on "Start at login". The app owns the setting (the HKCU Run value)
    /// and calls this after spawn and after each `Event::StartAtLogin`.
    pub fn set_start_at_login(&self, on: bool) {
        self.send(Cmd::StartAtLogin(on));
    }

    /// Sets the check mark in the Recordings submenu. The app owns the setting and calls this
    /// after spawn and after each `Event::DeleteAfter24h`.
    pub fn set_delete_after_24h(&self, on: bool) {
        self.send(Cmd::DeleteAfter24h(on));
    }

    /// The transcripts in the Recent submenu, newest first (at most `RECENT`). The app calls this
    /// after spawn and after each dictation; `Event::CopyRecent(n)` names an item of this list.
    pub fn set_recent(&self, texts: Vec<String>) {
        self.send(Cmd::Recent(texts));
    }

    /// Switches the hook to `name` (`Hotkey::parse` syntax) and checks it in the Hotkey submenu.
    /// The app owns the setting and calls this after each `Event::Hotkey`.
    pub fn set_hotkey(&self, name: &str) -> std::result::Result<(), String> {
        let hotkey = Hotkey::parse(name)?;
        self.send(Cmd::Hotkey(hotkey, name.to_string()));
        Ok(())
    }

    pub fn quit(&self) {
        self.send(Cmd::Quit);
    }

    fn send(&self, cmd: Cmd) {
        if self.tx.send(cmd).is_ok() {
            // The window, not the thread: thread messages are lost while the tray menu is open.
            let _ =
                unsafe { PostMessageW(Some(HWND(self.hwnd as _)), WM_CMD, WPARAM(0), LPARAM(0)) };
        }
    }
}

/// Starts the input thread: installs the hook for the hotkey `name` (`Hotkey::parse`) and Esc, shows the overlay and adds
/// the tray icon. Events arrive on the receiver until Quit.
pub fn spawn(name: &str) -> Result<(Ui, Receiver<Event>)> {
    let hotkey = Hotkey::parse(name).map_err(|e| Error::new(E_INVALIDARG, e))?;
    let name = name.to_string();
    let (events, rx) = channel();
    let (tx, cmds) = channel();
    let (ready_tx, ready) = sync_channel(1);
    std::thread::Builder::new()
        .name("shepetal-input".into())
        .spawn(move || unsafe {
            let hwnd = init(hotkey, name, events, cmds).map(|h| h.0 as isize);
            let ok = hwnd.is_ok();
            let _ = ready_tx.send(hwnd.map_err(|e| (e.code(), e.message())));
            if !ok {
                return;
            }
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
                DispatchMessageW(&msg);
            }
            STATE.take();
            HOOK.take();
        })
        .map_err(|e| Error::new(E_FAIL, e.to_string()))?;
    let hwnd = ready
        .recv()
        .map_err(|_| Error::new(E_FAIL, "input thread died"))?;
    let hwnd = hwnd.map_err(|(code, msg)| Error::new(code, msg))?;
    Ok((Ui { tx, hwnd }, rx))
}

thread_local! {
    // Separate cells: the hook runs whenever the thread waits for messages, including inside
    // the tray menu's modal loop and cross-process sends, so it must never need STATE.
    static HOOK: RefCell<Option<Hook>> = const { RefCell::new(None) };
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
}

struct Hook {
    chord: Chord,
    events: Sender<Event>,
    handle: HHOOK,
}

impl Hook {
    fn emit(&self, ev: KeyEvent) {
        let _ = self.events.send(Event::Key(ev, Instant::now()));
    }
}

unsafe fn install_hook() -> Result<HHOOK> {
    let module = GetModuleHandleW(None)?;
    SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), Some(module.into()), 0)
}

unsafe extern "system" fn hook_proc(code: i32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let kb = &*(lp.0 as *const KBDLLHOOKSTRUCT);
        let down = matches!(wp.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN);
        let vk = kb.vkCode as u16;
        let eat = HOOK.with(|h| {
            let Ok(mut h) = h.try_borrow_mut() else {
                return false;
            };
            let Some(h) = h.as_mut() else { return false };
            if let Some(ev) = h.chord.feed(vk, down) {
                if ev.key == Key::Hotkey && ev.down && h.chord.hotkey().needs_mask() {
                    // Queued behind this key, while the hotkey is still down.
                    send_mask();
                }
                h.emit(ev);
            }
            h.chord.swallow(vk, down, RECORDING.load(Ordering::Relaxed))
        });
        if eat {
            return LRESULT(1);
        }
    }
    CallNextHookEx(None, code, wp, lp)
}

unsafe fn send_mask() {
    let key = |flags| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(MASK_VK),
                dwFlags: flags,
                ..Default::default()
            },
        },
    };
    SendInput(
        &[key(KEYBD_EVENT_FLAGS(0)), key(KEYEVENTF_KEYUP)],
        size_of::<INPUT>() as i32,
    );
}

/// Windows silently removes a low-level hook that once took too long (LowLevelHooksTimeout) and
/// drops key-ups that went to the secure desktop, so every second: re-install the hook and
/// release keys that are no longer down.
// ponytail: re-installs unconditionally, since Windows gives no signal when it drops a hook.
unsafe fn watch_hook() {
    HOOK.with(|h| {
        let Ok(mut h) = h.try_borrow_mut() else {
            return;
        };
        let Some(h) = h.as_mut() else { return };
        // New first, then the old one: no pumping in between, so no key is seen twice or missed.
        match install_hook() {
            Ok(new) => {
                let _ = UnhookWindowsHookEx(std::mem::replace(&mut h.handle, new));
            }
            Err(e) => eprintln!("shepetal: keyboard hook re-install failed: {e}"),
        }
        for ev in h.chord.release_stale(|vk| GetAsyncKeyState(vk as i32) < 0) {
            h.emit(ev);
        }
    });
}

struct State {
    ctrl: HWND,
    overlay: HWND,
    start: Instant,
    view: View,
    cmds: Receiver<Cmd>,
    events: Sender<Event>,
    painter: Painter,
    icon: HICON,
    paused: bool,
    start_at_login: bool,
    delete_after_24h: bool,
    recent: Vec<String>,
    /// The hotkey's name, for the check mark.
    hotkey: String,
    /// What the overlay shows now, to skip redraws that change nothing.
    shown: Option<(Frame, Rect, u32)>,
}

/// Runs `f` on the state unless it is already borrowed further up this thread's stack (a
/// re-entrant message); that message then gets the default handling.
fn with<R>(f: impl FnOnce(&mut State) -> R) -> Option<R> {
    STATE.with(|s| s.try_borrow_mut().ok()?.as_mut().map(f))
}

unsafe fn init(
    hotkey: Hotkey,
    name: String,
    events: Sender<Event>,
    cmds: Receiver<Cmd>,
) -> Result<HWND> {
    // Physical pixels on every monitor, whatever the app's manifest says.
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    let instance: HINSTANCE = GetModuleHandleW(None)?.into();
    TASKBAR_CREATED.store(
        RegisterWindowMessageW(w!("TaskbarCreated")),
        Ordering::Relaxed,
    );
    let class = WNDCLASSW {
        lpfnWndProc: Some(wndproc),
        hInstance: instance,
        lpszClassName: CLASS,
        ..Default::default()
    };
    // Fails harmlessly if a previous spawn registered it.
    RegisterClassW(&class);
    // A hidden window owns the tray icon and its menu (the overlay can never be foreground).
    let ctrl = CreateWindowExW(
        WINDOW_EX_STYLE(0),
        CLASS,
        w!("shepetal"),
        WS_OVERLAPPED,
        0,
        0,
        0,
        0,
        None,
        None,
        Some(instance),
        None,
    )?;
    let ex =
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT;
    let overlay = CreateWindowExW(
        ex,
        CLASS,
        w!("shepetal 🤫"),
        WS_POPUP,
        0,
        0,
        0,
        0,
        None,
        None,
        Some(instance),
        None,
    )?;
    let painter = Painter::new()?;
    let icon = painter.icon(primary().1)?;
    let handle = install_hook()?;
    HOOK.set(Some(Hook {
        chord: Chord::new(hotkey),
        events: events.clone(),
        handle,
    }));
    let mut s = State {
        ctrl,
        overlay,
        start: Instant::now(),
        view: View::default(),
        cmds,
        events,
        painter,
        icon,
        paused: false,
        start_at_login: false,
        delete_after_24h: false,
        recent: Vec::new(),
        hotkey: name,
        shown: None,
    };
    s.tray(NIM_ADD); // fails before Explorer runs; TaskbarCreated adds it then
    s.redraw();
    let _ = ShowWindow(overlay, SW_SHOWNOACTIVATE);
    SetTimer(Some(ctrl), TIMER_WATCH, WATCH_MS, None);
    STATE.set(Some(s));
    Ok(ctrl)
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let handled = match msg {
        WM_CMD => with(|s| s.commands()),
        WM_TIMER => with(|s| s.timer(wp.0)),
        WM_TRAY => matches!(lp.0 as u32, WM_LBUTTONUP | WM_RBUTTONUP).then(|| menu()),
        WM_DISPLAYCHANGE | WM_SETTINGCHANGE | WM_DPICHANGED => with(|s| s.redraw()),
        m if m == TASKBAR_CREATED.load(Ordering::Relaxed) => with(|s| s.tray(NIM_ADD)),
        _ => None,
    };
    match handled {
        Some(()) => LRESULT(0),
        None => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

impl State {
    fn now(&self) -> u64 {
        self.start.elapsed().as_millis() as u64
    }

    unsafe fn commands(&mut self) {
        while let Ok(cmd) = self.cmds.try_recv() {
            let now = self.now();
            match cmd {
                Cmd::Mode(m) => self.view.set_mode(m, now),
                Cmd::Hint(text, ms) => self.view.show_hint(&text, ms, now),
                Cmd::StartAtLogin(on) => self.start_at_login = on,
                Cmd::DeleteAfter24h(on) => self.delete_after_24h = on,
                Cmd::Recent(texts) => self.recent = texts,
                Cmd::Hotkey(hotkey, name) => {
                    HOOK.with(|h| {
                        if let Some(h) = h.borrow_mut().as_mut() {
                            if let Some(up) = h.chord.set_hotkey(hotkey) {
                                h.emit(up);
                            }
                        }
                    });
                    self.hotkey = name;
                }
                Cmd::Quit => return self.shutdown(),
            }
        }
        self.redraw();
        if self.view.animating(self.now()) {
            SetTimer(Some(self.ctrl), TIMER_ANIM, ANIM_MS, None);
        }
    }

    unsafe fn timer(&mut self, id: usize) {
        if id == TIMER_WATCH {
            watch_hook();
            // Another topmost window may have been raised above us.
            let flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
            let _ = SetWindowPos(self.overlay, Some(HWND_TOPMOST), 0, 0, 0, 0, flags);
        }
        self.redraw(); // also picks up work-area and DPI changes
        if id == TIMER_ANIM && !self.view.animating(self.now()) {
            let _ = KillTimer(Some(self.ctrl), TIMER_ANIM);
        }
    }

    unsafe fn redraw(&mut self) {
        let (work, dpi) = primary();
        let frame = self.view.frame(self.now());
        let key = (frame, work, dpi);
        if self.shown.as_ref() == Some(&key) {
            return;
        }
        match self.painter.overlay(self.overlay, &key.0, work, dpi) {
            Ok(()) => self.shown = Some(key),
            Err(e) => eprintln!("shepetal: overlay draw failed: {e}"),
        }
    }

    unsafe fn tray(&self, msg: NOTIFY_ICON_MESSAGE) {
        let mut nid = NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: self.ctrl,
            uID: 1,
            uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
            uCallbackMessage: WM_TRAY,
            hIcon: self.icon,
            ..Default::default()
        };
        for (d, c) in nid.szTip.iter_mut().zip("shepetal".encode_utf16()) {
            *d = c;
        }
        if !Shell_NotifyIconW(msg, &nid).as_bool() && msg != NIM_ADD {
            eprintln!("shepetal: tray icon update failed");
        }
    }

    unsafe fn shutdown(&mut self) {
        self.tray(NIM_DELETE);
        HOOK.with(|h| {
            if let Some(h) = h.borrow_mut().take() {
                let _ = UnhookWindowsHookEx(h.handle);
            }
        });
        let _ = DestroyWindow(self.overlay);
        let _ = DestroyWindow(self.ctrl);
        let _ = DestroyIcon(self.icon);
        PostQuitMessage(0);
    }
}

/// The tray menu. Runs a modal loop, so the state is only borrowed before and after it.
unsafe fn menu() {
    let Some((ctrl, paused, login, delete, recent, hotkey)) = with(|s| {
        let recent: Vec<String> = s
            .recent
            .iter()
            .take(RECENT)
            .map(|t| recent_label(t))
            .collect();
        (
            s.ctrl,
            s.paused,
            s.start_at_login,
            s.delete_after_24h,
            recent,
            s.hotkey.clone(),
        )
    }) else {
        return;
    };
    let Ok(menu) = build_menu(paused, login, delete, &recent, &hotkey) else {
        return;
    };
    let mut pt = POINT::default();
    let _ = GetCursorPos(&mut pt);
    let _ = SetForegroundWindow(ctrl); // else the menu stays open when clicking elsewhere
    let flags = TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON;
    let id = TrackPopupMenu(menu, flags, pt.x, pt.y, None, ctrl, None).0 as usize;
    let _ = PostMessageW(Some(ctrl), WM_NULL, WPARAM(0), LPARAM(0));
    let _ = DestroyMenu(menu);
    with(|s| match id {
        ID_OPEN => {
            let _ = s.events.send(Event::Open);
        }
        ID_PAUSE => {
            s.paused = !s.paused;
            let _ = s.events.send(Event::Pause(s.paused));
        }
        ID_LOGIN => {
            let _ = s.events.send(Event::StartAtLogin);
        }
        id if (ID_HOTKEY..ID_HOTKEY + HOTKEYS.len()).contains(&id) => {
            let _ = s.events.send(Event::Hotkey(id - ID_HOTKEY));
        }
        id if (ID_RECENT..ID_RECENT + RECENT).contains(&id) => {
            let _ = s.events.send(Event::CopyRecent(id - ID_RECENT));
        }
        id if (ID_RECORDINGS..ID_RECORDINGS + 2).contains(&id) => {
            let (_, _, delete) = recordings_menu(s.delete_after_24h)[id - ID_RECORDINGS];
            let _ = s.events.send(Event::DeleteAfter24h(delete));
        }
        ID_COFFEE => open_url("https://buymeacoffee.com/sorcecoder"),
        ID_SPONSORS => open_url("https://github.com/sponsors/backant-io"),
        ID_QUIT => {
            s.shutdown();
            let _ = s.events.send(Event::Quit);
        }
        _ => {}
    });
}

/// Opens `url` in the browser off this thread: launching it can take long enough to stall every
/// key press on the system, since they all wait for our hook.
fn open_url(url: &'static str) {
    std::thread::spawn(move || unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED); // ShellExecute wants COM
        let url = HSTRING::from(url);
        let none = PCWSTR::null();
        ShellExecuteW(None, w!("open"), &url, none, none, SW_SHOWNORMAL);
    });
}

unsafe fn build_menu(
    paused: bool,
    login: bool,
    delete_after_24h: bool,
    recent: &[String],
    hotkey: &str,
) -> Result<HMENU> {
    let check = |on| MF_STRING | if on { MF_CHECKED } else { MF_UNCHECKED };
    let menu = CreatePopupMenu()?;
    let donate = CreatePopupMenu()?;
    AppendMenuW(donate, MF_STRING, ID_COFFEE, w!("Buy Me a Coffee"))?;
    AppendMenuW(donate, MF_STRING, ID_SPONSORS, w!("GitHub Sponsors"))?;
    AppendMenuW(menu, MF_STRING, ID_OPEN, w!("Open"))?;
    let history = CreatePopupMenu()?;
    for (i, label) in recent.iter().enumerate() {
        AppendMenuW(
            history,
            MF_STRING,
            ID_RECENT + i,
            &HSTRING::from(label.as_str()),
        )?;
    }
    if recent.is_empty() {
        AppendMenuW(history, MF_STRING | MF_GRAYED, 0, w!("Nothing yet"))?;
    }
    AppendMenuW(
        menu,
        MF_POPUP,
        history.0 as usize,
        w!("Recent (click to copy)"),
    )?;
    AppendMenuW(menu, check(paused), ID_PAUSE, w!("Pause"))?;
    let keys = CreatePopupMenu()?;
    for (i, (name, on)) in hotkey_menu(hotkey).into_iter().enumerate() {
        AppendMenuW(keys, check(on), ID_HOTKEY + i, &HSTRING::from(name))?;
    }
    AppendMenuW(menu, MF_POPUP, keys.0 as usize, w!("Hotkey"))?;
    let recordings = CreatePopupMenu()?;
    for (i, (label, on, _)) in recordings_menu(delete_after_24h).into_iter().enumerate() {
        AppendMenuW(
            recordings,
            check(on),
            ID_RECORDINGS + i,
            &HSTRING::from(label),
        )?;
    }
    AppendMenuW(menu, MF_POPUP, recordings.0 as usize, w!("Recordings"))?;
    AppendMenuW(menu, check(login), ID_LOGIN, w!("Start at login"))?;
    AppendMenuW(menu, MF_POPUP, donate.0 as usize, w!("Donate"))?;
    AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null())?;
    AppendMenuW(menu, MF_STRING, ID_QUIT, w!("Quit"))?;
    Ok(menu)
}

/// The primary monitor's work area (it holds (0, 0)) and its DPI.
unsafe fn primary() -> (Rect, u32) {
    let monitor = MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
    let mut mi = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    let _ = GetMonitorInfoW(monitor, &mut mi);
    let (mut dpi, mut dpi_y) = (96, 96);
    let _ = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi, &mut dpi_y);
    let r = mi.rcWork;
    (
        Rect {
            left: r.left,
            top: r.top,
            right: r.right,
            bottom: r.bottom,
        },
        dpi,
    )
}

/// Direct2D onto a 32-bit DIB, DirectWrite colour fonts for the emoji.
struct Painter {
    rt: ID2D1DCRenderTarget,
    dwrite: IDWriteFactory,
}

/// A rendered bitmap, still selected into its memory DC.
struct Dib {
    dc: HDC,
    bmp: HBITMAP,
    old: HGDIOBJ,
    /// BGRA pixels, premultiplied.
    bits: *mut [u8; 4],
}

impl Drop for Dib {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.old);
            let _ = DeleteObject(self.bmp.into());
            let _ = DeleteDC(self.dc);
        }
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

fn rect(left: f32, top: f32, right: f32, bottom: f32) -> D2D_RECT_F {
    D2D_RECT_F {
        left,
        top,
        right,
        bottom,
    }
}

impl Painter {
    unsafe fn new() -> Result<Painter> {
        let d2d: ID2D1Factory1 = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
        let props = D2D1_RENDER_TARGET_PROPERTIES {
            // Software: a few hundred pixels, and no device loss to recover from.
            r#type: D2D1_RENDER_TARGET_TYPE_SOFTWARE,
            pixelFormat: D2D1_PIXEL_FORMAT {
                format: DXGI_FORMAT_B8G8R8A8_UNORM,
                alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            dpiX: 96.0, // one DIP per pixel: the layout is already in pixels
            dpiY: 96.0,
            usage: D2D1_RENDER_TARGET_USAGE_NONE,
            minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
        };
        let rt = d2d.CreateDCRenderTarget(&props)?;
        let dwrite = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
        Ok(Painter { rt, dwrite })
    }

    unsafe fn format(
        &self,
        family: PCWSTR,
        weight: DWRITE_FONT_WEIGHT,
        px: f32,
    ) -> Result<IDWriteTextFormat> {
        let f = self.dwrite.CreateTextFormat(
            family,
            None,
            weight,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            px,
            w!("en-us"),
        )?;
        f.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER)?;
        f.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)?;
        f.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP)?;
        Ok(f)
    }

    unsafe fn brush(&self, [r, g, b]: [u8; 3], a: f32) -> Result<ID2D1SolidColorBrush> {
        let c = D2D1_COLOR_F {
            r: r as f32 / 255.0,
            g: g as f32 / 255.0,
            b: b as f32 / 255.0,
            a,
        };
        self.rt.CreateSolidColorBrush(&c, None)
    }

    unsafe fn text(
        &self,
        s: &[u16],
        f: &IDWriteTextFormat,
        r: D2D_RECT_F,
        brush: &ID2D1SolidColorBrush,
    ) {
        let opts = D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT;
        self.rt
            .DrawText(s, f, &r, brush, opts, DWRITE_MEASURING_MODE_NATURAL);
    }

    /// 🤫 centred in a `size` square at the origin, at the Mac's proportions (13 in 18).
    unsafe fn emoji(&self, size: f32, em: f32) -> Result<()> {
        let f = self.format(w!("Segoe UI Emoji"), DWRITE_FONT_WEIGHT_NORMAL, em)?;
        self.text(
            &wide("🤫"),
            &f,
            rect(0.0, 0.0, size, size),
            &self.brush([0, 0, 0], 1.0)?,
        );
        Ok(())
    }

    unsafe fn render(&self, w: i32, h: i32, draw: impl FnOnce() -> Result<()>) -> Result<Dib> {
        let header = BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h, // top-down
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let info = BITMAPINFO {
            bmiHeader: header,
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let bmp = CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0)?;
        let dc = CreateCompatibleDC(None);
        let old = SelectObject(dc, bmp.into());
        let dib = Dib {
            dc,
            bmp,
            old,
            bits: bits as *mut [u8; 4],
        };
        self.rt.BindDC(
            dc,
            &RECT {
                left: 0,
                top: 0,
                right: w,
                bottom: h,
            },
        )?;
        self.rt.BeginDraw();
        self.rt.Clear(Some(&D2D1_COLOR_F::default()));
        let drawn = draw();
        self.rt.EndDraw(None, None)?;
        drawn.map(|()| dib)
    }

    /// Draws `frame` and moves the overlay to where it belongs, in one UpdateLayeredWindow.
    unsafe fn overlay(&self, hwnd: HWND, frame: &Frame, work: Rect, dpi: u32) -> Result<()> {
        let k = dpi as f32 / 96.0;
        let size = scale(SIZE, dpi);
        let label = match &frame.label {
            Some(t) => {
                let (t, f) = (
                    wide(t),
                    self.format(w!("Segoe UI"), DWRITE_FONT_WEIGHT_MEDIUM, 11.0 * k)?,
                );
                let layout = self.dwrite.CreateTextLayout(&t, &f, 4096.0, 4096.0)?;
                let mut m = DWRITE_TEXT_METRICS::default();
                layout.GetMetrics(&mut m)?;
                let width = m.widthIncludingTrailingWhitespace.ceil() as i32 + 2 * scale(4, dpi);
                Some((t, f, width))
            }
            None => None,
        };
        let r = overlay_rect(work, dpi, label.as_ref().map_or(0, |l| l.2));
        let (w, h) = (r.right - r.left, r.bottom - r.top);
        let s = size as f32;
        let dib = self.render(w, h, || {
            self.emoji(s, 13.0 / 18.0 * s)?;
            if let Some((colour, alpha)) = frame.ring {
                let stroke = (2.0 * k).max(1.0);
                let ring = D2D1_ROUNDED_RECT {
                    rect: rect(
                        stroke / 2.0,
                        stroke / 2.0,
                        s - stroke / 2.0,
                        s - stroke / 2.0,
                    ),
                    radiusX: (s - stroke) / 2.0,
                    radiusY: (s - stroke) / 2.0,
                };
                self.rt
                    .DrawRoundedRectangle(&ring, &self.brush(colour, alpha)?, stroke, None);
            }
            if let Some((t, f, width)) = &label {
                let x = (size + scale(GAP, dpi)) as f32;
                let r = rect(x, 2.0 * k, x + *width as f32, s - 2.0 * k);
                let bg = D2D1_ROUNDED_RECT {
                    rect: r,
                    radiusX: 4.0 * k,
                    radiusY: 4.0 * k,
                };
                self.rt
                    .FillRoundedRectangle(&bg, &self.brush([0, 0, 0], 0.75)?);
                self.text(t, f, r, &self.brush([255, 255, 255], 1.0)?);
            }
            Ok(())
        })?;
        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            SourceConstantAlpha: 255,
            AlphaFormat: AC_SRC_ALPHA as u8,
            ..Default::default()
        };
        let (pos, sz) = (
            POINT {
                x: r.left,
                y: r.top,
            },
            SIZE { cx: w, cy: h },
        );
        UpdateLayeredWindow(
            hwnd,
            None,
            Some(&pos),
            Some(&sz),
            Some(dib.dc),
            Some(&POINT::default()),
            COLORREF(0),
            Some(&blend),
            ULW_ALPHA,
        )
    }

    /// The 🤫 tray icon at the small-icon size for `dpi`.
    unsafe fn icon(&self, dpi: u32) -> Result<HICON> {
        let px = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
        let dib = self.render(px, px, || self.emoji(px as f32, 0.85 * px as f32))?;
        // Icons take straight alpha; Direct2D wrote premultiplied. Flush GDI before reading.
        let _ = GdiFlush();
        for p in std::slice::from_raw_parts_mut(dib.bits, (px * px) as usize) {
            let a = p[3] as u32;
            if a != 0 && a != 255 {
                for c in &mut p[..3] {
                    *c = (*c as u32 * 255 / a) as u8;
                }
            }
        }
        SelectObject(dib.dc, dib.old); // CreateIconIndirect copies the bitmap; release it first
        let mask = CreateBitmap(px, px, 1, 1, None);
        let info = ICONINFO {
            fIcon: true.into(),
            hbmMask: mask,
            hbmColor: dib.bmp,
            ..Default::default()
        };
        let icon = CreateIconIndirect(&info);
        let _ = DeleteObject(mask.into());
        icon
    }
}
