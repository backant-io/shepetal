//! shepetal.exe's own windows. The system message box plays the sound of its icon (or the default
//! beep), and shepetal makes no sounds (Pavel, 2026-10-21), so:
//! - `ask`: a plain dialog with buttons for the questions at start. Standard controls, so the
//!   keyboard (Tab, Enter, Esc) and screen readers work.
//! - `Card`: the one-click Record? offer for a detected meeting, just above the 🤫. It never
//!   takes focus, so a click on it leaves the call (and a running dictation's window) in front.
//! - `Transcripts`: the Meeting transcript window, shown once a recorded meeting is transcribed.
//!   It comes up in front without taking the focus, and takes it only when clicked.

use crate::meeting;
use crate::transcript::{self, Button, Meeting};
use std::cell::{Cell, RefCell};
use std::mem::size_of;
use std::path::Path;
use std::ptr::{null, null_mut};
use std::sync::mpsc::{sync_channel, Sender};
use std::thread;
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::*;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, SetFocus};
use windows_sys::Win32::UI::HiDpi::{GetDpiForMonitor, SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, MDT_EFFECTIVE_DPI};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain([0]).collect()
}

const SS_NOPREFIX: u32 = 0x80; // an "&" in a path is text, not a mnemonic
const FIRST_BUTTON: usize = 100;
const TEXT_W: i32 = 400;
const PAD: i32 = 16;
const BUTTON_W: i32 = 96;
const BUTTON_H: i32 = 28;

thread_local! {
    static CHOICE: Cell<Option<usize>> = const { Cell::new(None) };
}

/// Shows `text` with one button per label (the first is the default) and waits. The index of the
/// button clicked, or None if the dialog was closed or Esc pressed.
// ponytail: DPI-unaware like the rest of the main thread, so Windows scales it up (a bit soft at 150 %).
pub fn ask(text: &str, buttons: &[&str]) -> Option<usize> {
    unsafe {
        let inst = GetModuleHandleW(null());
        let class = wide("ShepetalDialog");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(dialog_proc),
            hInstance: inst,
            lpszClassName: class.as_ptr(),
            hCursor: LoadCursorW(null_mut(), IDC_ARROW),
            // The colour static text and buttons paint behind themselves.
            hbrBackground: GetSysColorBrush(COLOR_3DFACE),
            ..Default::default()
        };
        RegisterClassW(&wc); // fails harmlessly on the second call

        let font = message_font();
        let text = wide(text);
        let mut t = RECT { left: 0, top: 0, right: TEXT_W, bottom: 0 };
        let dc = GetDC(null_mut());
        let old = SelectObject(dc, font);
        DrawTextW(dc, text.as_ptr(), -1, &mut t, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
        SelectObject(dc, old);
        ReleaseDC(null_mut(), dc);

        let row = buttons.len() as i32 * (BUTTON_W + 8) - 8;
        let (cw, ch) = (TEXT_W.max(row) + 2 * PAD, PAD + t.bottom + PAD + BUTTON_H + PAD);
        let (style, ex) = (WS_CAPTION | WS_SYSMENU, WS_EX_DLGMODALFRAME);
        let mut r = RECT { left: 0, top: 0, right: cw, bottom: ch };
        AdjustWindowRectEx(&mut r, style, 0, ex);
        let (w, h) = (r.right - r.left, r.bottom - r.top);
        let (x, y) = ((GetSystemMetrics(SM_CXSCREEN) - w) / 2, (GetSystemMetrics(SM_CYSCREEN) - h) / 3);
        let title = wide("Shepetal");
        let hwnd = CreateWindowExW(ex, class.as_ptr(), title.as_ptr(), style, x, y, w, h, null_mut(), null_mut(), inst, null());
        if hwnd.is_null() {
            DeleteObject(font);
            return None;
        }
        let child = |class: &str, label: &[u16], style: u32, rect: (i32, i32, i32, i32), id: usize| {
            let c = CreateWindowExW(0, wide(class).as_ptr(), label.as_ptr(), WS_CHILD | WS_VISIBLE | style, rect.0, rect.1, rect.2, rect.3, hwnd, id as _, inst, null());
            SendMessageW(c, WM_SETFONT, font as usize, 0);
            c
        };
        child("STATIC", &text, SS_NOPREFIX, (PAD, PAD, TEXT_W, t.bottom), 0);
        let mut first = null_mut();
        for (i, label) in buttons.iter().enumerate() {
            let x = cw - PAD - row + i as i32 * (BUTTON_W + 8);
            let kind = (if i == 0 { BS_DEFPUSHBUTTON } else { BS_PUSHBUTTON }) as u32;
            let b = child("BUTTON", &wide(label), WS_TABSTOP | kind, (x, ch - PAD - BUTTON_H, BUTTON_W, BUTTON_H), FIRST_BUTTON + i);
            if i == 0 {
                first = b;
            }
        }

        CHOICE.set(None);
        ShowWindow(hwnd, SW_SHOWNORMAL);
        SetForegroundWindow(hwnd);
        SetFocus(first);
        let mut msg = MSG::default();
        while IsWindow(hwnd) != 0 && GetMessageW(&mut msg, null_mut(), 0, 0) > 0 {
            if IsDialogMessageW(hwnd, &msg) == 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        DeleteObject(font);
        CHOICE.take()
    }
}

/// The font of the system's own dialogs.
unsafe fn message_font() -> HFONT {
    let mut ncm = NONCLIENTMETRICSW { cbSize: size_of::<NONCLIENTMETRICSW>() as u32, ..Default::default() };
    SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, ncm.cbSize, (&raw mut ncm).cast(), 0);
    CreateFontIndirectW(&ncm.lfMessageFont)
}

unsafe extern "system" fn dialog_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_COMMAND {
        // Enter or Space on a button sends its id, Enter elsewhere IDOK (the first button), and
        // Esc IDCANCEL, which chooses nothing.
        let choice = match wp & 0xFFFF {
            id if id >= FIRST_BUTTON => Some(Some(id - FIRST_BUTTON)),
            id if id == IDOK as usize => Some(Some(0)),
            id if id == IDCANCEL as usize => Some(None),
            _ => None,
        };
        if let Some(choice) = choice {
            CHOICE.set(choice);
            DestroyWindow(hwnd);
        }
        return 0;
    }
    DefWindowProcW(hwnd, msg, wp, lp)
}

/// Shows or hides the card from any thread. Its window runs on its own thread.
pub struct Card {
    hwnd: isize,
}

/// A card command: a boxed label to show, or 0 to hide.
const WM_CARD: u32 = WM_APP;

struct CardState {
    record: Sender<()>,
    font: HFONT,
    /// The label, Record and Not now: text, left edge and width, in client pixels.
    parts: [(Vec<u16>, i32, i32); 3],
    /// Pixels on each side of Record and Not now that still count as a click on them.
    slack: i32,
}

impl CardState {
    fn hit(&self, part: usize, x: i32) -> bool {
        let (_, left, w) = self.parts[part];
        (left - self.slack..left + w + self.slack).contains(&x)
    }
}

thread_local! {
    static CARD: RefCell<Option<CardState>> = const { RefCell::new(None) };
}

/// Runs `f` on the card's state, unless a message further up this thread's stack holds it.
fn with<R>(f: impl FnOnce(&mut CardState) -> R) -> Option<R> {
    CARD.with(|c| c.try_borrow_mut().ok()?.as_mut().map(f))
}

impl Card {
    /// A click on Record sends `()` on `record`, which is what `meetings::watch` waits for.
    pub fn spawn(record: Sender<()>) -> Result<Card, String> {
        let (tx, rx) = sync_channel(1);
        thread::Builder::new()
            .name("shepetal-card".into())
            .spawn(move || unsafe {
                SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
                let inst = GetModuleHandleW(null());
                let class = wide("ShepetalCard");
                let wc = WNDCLASSW { lpfnWndProc: Some(card_proc), hInstance: inst, lpszClassName: class.as_ptr(), ..Default::default() };
                RegisterClassW(&wc);
                let ex = WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
                let hwnd = CreateWindowExW(ex, class.as_ptr(), class.as_ptr(), WS_POPUP, 0, 0, 0, 0, null_mut(), null_mut(), inst, null());
                if hwnd.is_null() {
                    let _ = tx.send(Err(std::io::Error::last_os_error().to_string()));
                    return;
                }
                CARD.set(Some(CardState { record, font: null_mut(), parts: Default::default(), slack: 0 }));
                let _ = tx.send(Ok(hwnd as isize));
                let mut msg = MSG::default();
                while GetMessageW(&mut msg, null_mut(), 0, 0) > 0 {
                    DispatchMessageW(&msg);
                }
            })
            .map_err(|e| e.to_string())?;
        let hwnd = rx.recv().map_err(|_| "the card thread died".to_string())??;
        Ok(Card { hwnd })
    }

    pub fn offer(&self, label: &str) {
        let boxed = Box::into_raw(Box::new(label.to_string()));
        if unsafe { PostMessageW(self.hwnd as HWND, WM_CARD, 0, boxed as LPARAM) } == 0 {
            drop(unsafe { Box::from_raw(boxed) });
        }
    }

    pub fn hide(&self) {
        unsafe { PostMessageW(self.hwnd as HWND, WM_CARD, 0, 0) };
    }
}

const RECORD: &str = "Record";
const NOT_NOW: &str = "Not now";

unsafe extern "system" fn card_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_CARD if lp == 0 => {
            ShowWindow(hwnd, SW_HIDE);
        }
        WM_CARD => {
            let label = *Box::from_raw(lp as *mut String);
            with(|c| c.show(hwnd, &label));
        }
        // A click must not activate the card: the call keeps the focus.
        WM_MOUSEACTIVATE => return MA_NOACTIVATE as LRESULT,
        WM_SETCURSOR => {
            SetCursor(LoadCursorW(null_mut(), IDC_HAND));
            return 1;
        }
        WM_LBUTTONUP => {
            let x = (lp & 0xFFFF) as i16 as i32;
            let (record, not_now) = with(|c| (c.hit(1, x), c.hit(2, x))).unwrap_or_default();
            if record {
                with(|c| c.record.send(()));
            }
            if record || not_now {
                ShowWindow(hwnd, SW_HIDE);
            }
        }
        // Painting validates the window; without the state, the default handler must.
        WM_PAINT if with(|c| c.paint(hwnd)).is_none() => return DefWindowProcW(hwnd, msg, wp, lp),
        WM_PAINT => {}
        _ => return DefWindowProcW(hwnd, msg, wp, lp),
    }
    0
}

/// COLORREF is 0x00BBGGRR.
const fn rgb(r: u8, g: u8, b: u8) -> u32 {
    r as u32 | (g as u32) << 8 | (b as u32) << 16
}

impl CardState {
    /// Lays the card out for the primary display's DPI, places it above the 🤫 and shows it
    /// without activating it.
    unsafe fn show(&mut self, hwnd: HWND, label: &str) {
        let monitor = MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
        let mut mi = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        GetMonitorInfoW(monitor, &mut mi);
        let (mut dpi, mut dpi_y) = (96, 96);
        GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi, &mut dpi_y);
        let px = |n: i32| input::scale(n, dpi);

        if !self.font.is_null() {
            DeleteObject(self.font);
        }
        let face = wide("Segoe UI");
        self.font = CreateFontW(-px(13), 0, 0, 0, FW_NORMAL as i32, 0, 0, 0, DEFAULT_CHARSET as u32, 0, 0, CLEARTYPE_QUALITY as u32, 0, face.as_ptr());
        let dc = GetDC(hwnd);
        let old = SelectObject(dc, self.font);
        let (pad, gap) = (px(10), px(16));
        let (mut x, mut h) = (pad, 0);
        for (part, text) in self.parts.iter_mut().zip([label, RECORD, NOT_NOW]) {
            let text = wide(text);
            let mut r = RECT::default();
            DrawTextW(dc, text.as_ptr(), -1, &mut r, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
            *part = (text, x, r.right);
            (x, h) = (x + r.right + gap, h.max(r.bottom));
        }
        SelectObject(dc, old);
        ReleaseDC(hwnd, dc);
        self.slack = gap / 2;
        let (w, h) = (x - gap + pad, h + 2 * px(8));

        let wa = mi.rcWork;
        let work = input::Rect { left: wa.left, top: wa.top, right: wa.right, bottom: wa.bottom };
        let r = meeting::card_rect(work, dpi, w, h);
        SetWindowPos(hwnd, HWND_TOPMOST, r.left, r.top, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        InvalidateRect(hwnd, null(), 1);
    }

    unsafe fn paint(&self, hwnd: HWND) {
        let mut ps = PAINTSTRUCT::default();
        let dc = BeginPaint(hwnd, &mut ps);
        let mut r = RECT::default();
        GetClientRect(hwnd, &mut r);
        let bg = CreateSolidBrush(rgb(32, 32, 32));
        FillRect(dc, &r, bg);
        DeleteObject(bg);
        let old = SelectObject(dc, self.font);
        SetBkMode(dc, TRANSPARENT as i32);
        // The label, Record in the recording ring's red, Not now dimmed.
        for ((text, left, _), color) in self.parts.iter().zip([rgb(230, 230, 230), rgb(255, 59, 48), rgb(160, 160, 160)]) {
            SetTextColor(dc, color);
            let mut t = RECT { left: *left, ..r };
            DrawTextW(dc, text.as_ptr(), -1, &mut t, DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);
        }
        SelectObject(dc, old);
        EndPaint(hwnd, &ps);
    }
}

/// Shows meetings in the Meeting transcript window from any thread. Its window runs on its own
/// thread; one window serves every meeting, the latest replacing the one before.
pub struct Transcripts {
    hwnd: isize,
}

/// A boxed `Meeting` to show.
const WM_TRANSCRIPT: u32 = WM_APP;
const ID_TEXT: usize = 200;
const ID_STATUS: usize = 201;
const ID_BUTTON: usize = 210;
const BUTTONS: [(&str, Button); 3] =
    [("Copy transcript", Button::CopyTranscript), ("Copy summary", Button::CopySummary), ("Open folder", Button::OpenFolder)];
const WIDE_BUTTON: i32 = 120;
/// How long "Copied" stays.
const STATUS_MS: u32 = 2000;

thread_local! {
    static TRANSCRIPT: RefCell<Option<transcript::Window<Win>>> = const { RefCell::new(None) };
}

impl Transcripts {
    pub fn spawn() -> Result<Transcripts, String> {
        let (tx, rx) = sync_channel(1);
        thread::Builder::new()
            .name("shepetal-transcript".into())
            .spawn(move || unsafe {
                // ponytail: DPI-unaware like `ask`, so Windows scales it up (a bit soft at 150 %).
                let inst = GetModuleHandleW(null());
                let class = wide("ShepetalTranscript");
                let wc = WNDCLASSW {
                    lpfnWndProc: Some(transcript_proc),
                    hInstance: inst,
                    lpszClassName: class.as_ptr(),
                    hCursor: LoadCursorW(null_mut(), IDC_ARROW),
                    hbrBackground: GetSysColorBrush(COLOR_3DFACE),
                    ..Default::default()
                };
                RegisterClassW(&wc);
                let title = wide(transcript::TITLE);
                let (x, size) = (CW_USEDEFAULT, (680, 560));
                let hwnd = CreateWindowExW(0, class.as_ptr(), title.as_ptr(), WS_OVERLAPPEDWINDOW, x, x, size.0, size.1, null_mut(), null_mut(), inst, null());
                if hwnd.is_null() {
                    let _ = tx.send(Err(std::io::Error::last_os_error().to_string()));
                    return;
                }
                let font = message_font();
                let child = |class: &str, label: &str, style: u32, id: usize| {
                    let c = CreateWindowExW(0, wide(class).as_ptr(), wide(label).as_ptr(), WS_CHILD | WS_VISIBLE | style, 0, 0, 0, 0, hwnd, id as _, inst, null());
                    SendMessageW(c, WM_SETFONT, font as usize, 0);
                };
                // Read-only but selectable, so Ctrl+C copies a selection.
                let text = (ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL) as u32;
                child("EDIT", "", WS_BORDER | WS_VSCROLL | WS_TABSTOP | text, ID_TEXT);
                for (i, (label, _)) in BUTTONS.iter().enumerate() {
                    child("BUTTON", label, WS_TABSTOP | BS_PUSHBUTTON as u32, ID_BUTTON + i);
                }
                child("STATIC", "", SS_NOPREFIX, ID_STATUS);
                layout(hwnd);
                TRANSCRIPT.set(Some(transcript::Window::new(Win { hwnd })));
                let _ = tx.send(Ok(hwnd as isize));
                let mut msg = MSG::default();
                while GetMessageW(&mut msg, null_mut(), 0, 0) > 0 {
                    // Tab between the text and the buttons, Esc closes.
                    if IsDialogMessageW(hwnd, &msg) == 0 {
                        TranslateMessage(&msg);
                        DispatchMessageW(&msg);
                    }
                }
            })
            .map_err(|e| e.to_string())?;
        let hwnd = rx.recv().map_err(|_| "the transcript window's thread died".to_string())??;
        Ok(Transcripts { hwnd })
    }

    pub fn show(&self, m: Meeting) {
        let boxed = Box::into_raw(Box::new(m));
        if unsafe { PostMessageW(self.hwnd as HWND, WM_TRANSCRIPT, 0, boxed as LPARAM) } == 0 {
            drop(unsafe { Box::from_raw(boxed) });
        }
    }
}

/// Text on top, the buttons and the status in a row under it.
unsafe fn layout(hwnd: HWND) {
    let mut r = RECT::default();
    GetClientRect(hwnd, &mut r);
    let row = r.bottom - PAD - BUTTON_H;
    let place = |id: usize, x: i32, y: i32, w: i32, h: i32| MoveWindow(GetDlgItem(hwnd, id as i32), x, y, w.max(0), h.max(0), 1);
    place(ID_TEXT, PAD, PAD, r.right - 2 * PAD, row - 2 * PAD);
    let mut x = PAD;
    for i in 0..BUTTONS.len() {
        place(ID_BUTTON + i, x, row, WIDE_BUTTON, BUTTON_H);
        x += WIDE_BUTTON + 8;
    }
    place(ID_STATUS, x + 8, row + 6, r.right - x - 8 - PAD, BUTTON_H - 6);
}

/// The transcript window as `transcript::Window` sees it.
struct Win {
    hwnd: HWND,
}

impl transcript::Shell for Win {
    fn present(&mut self, text: &str, summary: bool) {
        unsafe {
            // An edit control shows a bare "\n" as nothing.
            SetWindowTextW(GetDlgItem(self.hwnd, ID_TEXT as i32), wide(&text.replace('\n', "\r\n")).as_ptr());
            EnableWindow(GetDlgItem(self.hwnd, (ID_BUTTON + 1) as i32), summary as i32);
            // Never steals the keyboard from the app in front (rule 8): shown without activating,
            // then raised above that app by a TOPMOST and NOTOPMOST round trip, still without.
            ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
            let keep = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
            SetWindowPos(self.hwnd, HWND_TOPMOST, 0, 0, 0, 0, keep);
            SetWindowPos(self.hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, keep);
        }
    }

    fn copy(&mut self, text: &str) -> Result<(), String> {
        insert::copy(text).map_err(|e| e.to_string())
    }

    fn open(&mut self, dir: &Path) {
        // Off this thread: Explorer's handler may pump messages while the window's state is in use.
        let dir = dir.to_string_lossy().into_owned();
        thread::spawn(move || crate::win::open(&dir));
    }

    fn status(&mut self, text: &str) {
        unsafe {
            SetWindowTextW(GetDlgItem(self.hwnd, ID_STATUS as i32), wide(text).as_ptr());
            if !text.is_empty() {
                SetTimer(self.hwnd, 1, STATUS_MS, None);
            }
        }
    }
}

/// Runs `f` on the window's state, unless a message further up this thread's stack holds it.
fn with_window(f: impl FnOnce(&mut transcript::Window<Win>)) {
    TRANSCRIPT.with(|t| t.try_borrow_mut().ok().and_then(|mut t| t.as_mut().map(f)));
}

unsafe extern "system" fn transcript_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_TRANSCRIPT => {
            let m = *Box::from_raw(lp as *mut Meeting);
            with_window(|w| w.show(m));
        }
        WM_COMMAND => match wp & 0xFFFF {
            id if (ID_BUTTON..ID_BUTTON + BUTTONS.len()).contains(&id) => with_window(|w| w.click(BUTTONS[id - ID_BUTTON].1)),
            id if id == IDCANCEL as usize => {
                ShowWindow(hwnd, SW_HIDE);
            }
            _ => {}
        },
        WM_TIMER => {
            KillTimer(hwnd, wp);
            SetWindowTextW(GetDlgItem(hwnd, ID_STATUS as i32), wide("").as_ptr());
        }
        WM_SIZE => layout(hwnd),
        // Closing only hides it: the next meeting shows in the same window.
        WM_CLOSE => {
            ShowWindow(hwnd, SW_HIDE);
        }
        _ => return DefWindowProcW(hwnd, msg, wp, lp),
    }
    0
}
