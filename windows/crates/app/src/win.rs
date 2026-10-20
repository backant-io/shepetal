//! The Windows side of shepetal.exe: single instance, start at login, the mic privacy check,
//! dialogs, and the wiring of the sibling crates into `flow::Flow`.

use crate::system::{self, MIC_CONSENT, MIC_CONSENT_DESKTOP, MIC_SETTINGS, MUTEX, RUN_KEY, RUN_VALUE};
use std::path::PathBuf;
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
use windows_sys::Win32::System::Registry::{
    RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW, HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, REG_SZ, RRF_RT_REG_SZ,
};
use windows_sys::Win32::System::Threading::CreateMutexW;
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, GetMessageW, MessageBoxW, TranslateMessage, IDYES, MB_ICONINFORMATION, MB_ICONQUESTION, MB_OK, MB_YESNO, MSG,
    SW_SHOWNORMAL,
};

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain([0]).collect()
}

/// Takes the named mutex. The handle stays open until the process exits, which frees the name.
fn already_running() -> bool {
    let h = unsafe { CreateMutexW(null(), 0, wide(MUTEX).as_ptr()) };
    !h.is_null() && unsafe { GetLastError() } == ERROR_ALREADY_EXISTS
}

fn reg_string(root: HKEY, key: &str, value: &str) -> Option<String> {
    let (key, value) = (wide(key), wide(value));
    let mut buf = [0u16; 2048];
    let mut bytes = std::mem::size_of_val(&buf) as u32;
    let r = unsafe { RegGetValueW(root, key.as_ptr(), value.as_ptr(), RRF_RT_REG_SZ, null_mut(), buf.as_mut_ptr().cast(), &mut bytes) };
    // `bytes` counts the terminating NUL.
    (r == ERROR_SUCCESS).then(|| String::from_utf16_lossy(&buf[..(bytes as usize / 2).saturating_sub(1)]))
}

pub fn starts_at_login() -> bool {
    reg_string(HKEY_CURRENT_USER, RUN_KEY, RUN_VALUE).is_some()
}

pub fn set_start_at_login(on: bool) -> Result<(), String> {
    let (key, name) = (wide(RUN_KEY), wide(RUN_VALUE));
    let r = if on {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let data = wide(&system::run_command(&exe));
        unsafe { RegSetKeyValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr(), REG_SZ, data.as_ptr().cast(), (data.len() * 2) as u32) }
    } else {
        unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr()) }
    };
    match r {
        ERROR_SUCCESS => Ok(()),
        ERROR_FILE_NOT_FOUND if !on => Ok(()),
        r => Err(format!("Could not change start at login (error {r})")),
    }
}

fn mic_allowed() -> bool {
    let device = reg_string(HKEY_LOCAL_MACHINE, MIC_CONSENT, "Value");
    let apps = reg_string(HKEY_CURRENT_USER, MIC_CONSENT, "Value");
    let desktop = reg_string(HKEY_CURRENT_USER, MIC_CONSENT_DESKTOP, "Value");
    system::mic_allowed([device.as_deref(), apps.as_deref(), desktop.as_deref()])
}

pub fn message(text: &str) {
    unsafe { MessageBoxW(null_mut(), wide(text).as_ptr(), wide("Shepetal").as_ptr(), MB_OK | MB_ICONINFORMATION) };
}

pub fn ask(text: &str) -> bool {
    unsafe { MessageBoxW(null_mut(), wide(text).as_ptr(), wide("Shepetal").as_ptr(), MB_YESNO | MB_ICONQUESTION) == IDYES }
}

/// Opens a URL or an ms-settings: page with its default handler.
pub fn open(target: &str) {
    unsafe { ShellExecuteW(null_mut(), wide("open").as_ptr(), wide(target).as_ptr(), null(), null(), SW_SHOWNORMAL) };
}

pub fn run() {
    if already_running() {
        message("Shepetal is already running. Its 🤫 is in the bottom-left corner, and its menu is in the tray.");
        return;
    }
    // Never fall back to a temp dir: recordings must stay in the user's own profile (goal rule 4).
    let Some(local) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from) else {
        message("Shepetal can't start: %LOCALAPPDATA% is not set, so there is nowhere private to keep your recordings.");
        return;
    };
    let _data = system::data_dir(&local);
    if !mic_allowed()
        && ask("Windows is keeping desktop apps away from the microphone, so Shepetal can't hear you.\n\n\
                Open the microphone settings now? Turn on \"Microphone access\", \"Let apps access your microphone\" \
                and \"Let desktop apps access your microphone\".")
    {
        open(MIC_SETTINGS);
    }
    let mut msg: MSG = unsafe { std::mem::zeroed() };
    while unsafe { GetMessageW(&mut msg, null_mut(), 0, 0) } > 0 {
        unsafe {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}
