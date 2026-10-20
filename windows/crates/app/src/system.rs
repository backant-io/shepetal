//! The names shepetal.exe shares with Windows and with the installer
//! (windows/installer/shepetal.iss), and the pure decisions made on them.

use std::path::Path;

/// Single instance. The installer's `AppMutex` names the same mutex, so setup and the uninstaller
/// ask the user to quit a running shepetal first. No `Global\` prefix: one instance per session.
pub const MUTEX: &str = "Shepetal.SingleInstance";

/// Start at login: a value under HKCU, written by the installer's "start at login" task and by
/// the tray toggle, removed by the uninstaller.
pub const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
pub const RUN_VALUE: &str = "Shepetal";

/// The Run value's data: the exe, quoted because the install path may hold spaces.
pub fn run_command(exe: &Path) -> String {
    format!("\"{}\"", exe.display())
}

/// Windows' three microphone switches. Desktop (unpackaged) apps get the mic only if none of
/// them is "Deny": Microphone access (HKLM), Let apps access your microphone (HKCU) and Let
/// desktop apps access your microphone (HKCU, `NonPackaged`). Each is a REG_SZ named `Value`.
pub const MIC_CONSENT: &str = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
pub const MIC_CONSENT_DESKTOP: &str = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged";
pub const MIC_SETTINGS: &str = "ms-settings:privacy-microphone";

/// `values`: device switch (HKLM), apps switch (HKCU), desktop apps switch (HKCU). A missing
/// value is the Windows default, which allows.
pub fn mic_allowed(values: [Option<&str>; 3]) -> bool {
    values.iter().all(|v| !v.is_some_and(|v| v.eq_ignore_ascii_case("Deny")))
}

/// The first-run question before the one download. The UI names no model, only its size.
pub fn download_question(bytes: u64) -> String {
    format!(
        "Shepetal turns your speech into text on this PC. It needs a speech model first ({} MB).\n\n\
         Download it now? This is the only time Shepetal goes online; your voice never leaves the PC.",
        bytes.div_ceil(1_000_000)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const ISS: &str = include_str!("../../../installer/shepetal.iss");

    #[test]
    fn installer_and_app_name_the_same_mutex_and_run_value() {
        // If these drift, setup overwrites a running exe, or the tray toggle and the
        // installer's task write two different Run values and the uninstaller leaves one behind.
        assert!(ISS.contains(&format!("AppMutex={MUTEX}")), "AppMutex in shepetal.iss");
        assert!(ISS.contains(&format!("#define RunValue \"{RUN_VALUE}\"")), "RunValue in shepetal.iss");
        assert!(ISS.contains(&format!("#define RunKey \"{RUN_KEY}\"")), "RunKey in shepetal.iss");
    }

    #[test]
    fn installer_is_per_user_and_keeps_recordings() {
        // No admin rights: the install goes to %LOCALAPPDATA%\Programs\Shepetal.
        assert!(ISS.contains("PrivilegesRequired=lowest"));
        assert!(ISS.contains(r"DefaultDirName={localappdata}\Programs\Shepetal"));
        // Goal rule 4: of the data dir (audio::data_dir, %LOCALAPPDATA%\Shepetal), the
        // uninstaller deletes only the models, never the recordings next to them.
        let data: Vec<&str> = ISS.lines().filter(|l| l.to_ascii_lowercase().contains(r"{localappdata}\shepetal")).collect();
        assert_eq!(data, [r#"Type: filesandordirs; Name: "{localappdata}\Shepetal\models""#]);
    }

    #[test]
    fn run_value_is_the_quoted_exe() {
        let exe = Path::new(r"C:\Users\Pavel Hegler\AppData\Local\Programs\Shepetal\shepetal.exe");
        assert_eq!(run_command(exe), format!("\"{}\"", exe.display()), "a path with a space must be quoted");
    }

    #[test]
    fn the_download_question_gives_the_size_but_names_no_model() {
        let q = download_question(59_721_011);
        assert!(q.contains("(60 MB)"), "{q}");
        for name in ["ggml", "whisper", "base", "large", "turbo", "q5", ".bin"] {
            assert!(!q.to_lowercase().contains(name), "{q} names the model ({name})");
        }
    }

    #[test]
    fn shepetal_on_windows_makes_no_sound() {
        // Pavel removed every sound (2026-10-21). The system message box plays its icon's sound,
        // so the app's dialogs are its own (dialog.rs), and no crate plays one either.
        let sources = [
            ("app/src/win.rs", include_str!("win.rs")),
            ("app/src/dialog.rs", include_str!("dialog.rs")),
            ("input/src/win.rs", include_str!("../../input/src/win.rs")),
            ("insert/src/win.rs", include_str!("../../insert/src/win.rs")),
            ("meetings/src/win.rs", include_str!("../../meetings/src/win.rs")),
        ];
        for (file, src) in sources {
            for api in ["MessageBox", "MessageBeep", "PlaySound", "Beep(", "sndPlaySound"] {
                assert!(!src.contains(api), "{file} uses {api}");
            }
        }
    }

    #[test]
    fn any_deny_switch_blocks_the_mic() {
        assert!(mic_allowed([None, None, None]), "missing values are the default, Allow");
        assert!(mic_allowed([Some("Allow"), Some("Allow"), Some("Allow")]));
        assert!(!mic_allowed([Some("Deny"), Some("Allow"), Some("Allow")]), "device switch");
        assert!(!mic_allowed([None, Some("Deny"), None]), "apps switch");
        assert!(!mic_allowed([None, None, Some("Deny")]), "desktop apps switch: the one shepetal.exe falls under");
        assert!(!mic_allowed([None, None, Some("deny")]));
        assert!(MIC_CONSENT_DESKTOP.starts_with(MIC_CONSENT));
    }
}
