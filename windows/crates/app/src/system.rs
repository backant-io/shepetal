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
