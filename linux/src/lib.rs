use std::path::{Path, PathBuf};

pub mod gesture;
pub mod insert;
pub mod meeting;
pub mod model;

pub const EV_KEY: u16 = 1;
pub const KEY_RIGHTCTRL: u16 = 97;

/// Decode one `struct input_event` (64-bit layout: timeval 16 bytes, type u16, code u16, value i32)
/// into (code, value) if it is a key event. value: 1 down, 0 up, 2 autorepeat.
pub fn key_event(buf: &[u8; 24]) -> Option<(u16, i32)> {
    let ty = u16::from_ne_bytes([buf[16], buf[17]]);
    let code = u16::from_ne_bytes([buf[18], buf[19]]);
    let value = i32::from_ne_bytes([buf[20], buf[21], buf[22], buf[23]]);
    (ty == EV_KEY).then_some((code, value))
}

/// Hotkey from a name or a raw evdev code (see linux/input-event-codes.h).
pub fn parse_key(s: &str) -> Option<u16> {
    match s.to_ascii_lowercase().as_str() {
        "rightctrl" => Some(KEY_RIGHTCTRL),
        "rightalt" => Some(100),
        "rightmeta" => Some(126),
        "capslock" => Some(58),
        "f13" => Some(183),
        n => n.parse().ok(),
    }
}

/// Every dictation's audio is kept in `<data_home>/shepetal/audio/` (0700) as `<stamp>.wav` (0600).
/// create_new is O_CREAT|O_EXCL, which also refuses an existing symlink at the path.
pub fn new_recording(data_home: &Path, stamp: u128) -> std::io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    let dir = data_home.join("shepetal").join("audio");
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
    let md = std::fs::symlink_metadata(&dir)?;
    if !md.is_dir() || md.permissions().mode() & 0o077 != 0 {
        return Err(std::io::Error::other(format!("{} must be a 0700 directory", dir.display())));
    }
    let path = dir.join(format!("{stamp}.wav"));
    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)?;
    Ok(path)
}

/// Every recording is kept. A cancelled one is renamed `<stamp>.cancelled.wav`, never deleted.
pub fn mark_cancelled(wav: &Path) -> std::io::Result<PathBuf> {
    let to = wav.with_extension("cancelled.wav");
    std::fs::rename(wav, &to)?;
    Ok(to)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recording_is_private_and_always_kept() {
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("shepetal-test-{}", std::process::id()));
        let wav = new_recording(&home, 1).unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&wav), 0o600);
        assert_eq!(mode(wav.parent().unwrap()), 0o700);
        assert!(new_recording(&home, 1).is_err(), "must never reuse an existing file");
        std::fs::write(&wav, b"RIFF").unwrap();
        let cancelled = mark_cancelled(&wav).unwrap();
        assert_eq!(cancelled.file_name().unwrap(), "1.cancelled.wav");
        assert_eq!(std::fs::read(&cancelled).unwrap(), b"RIFF", "cancelled audio must be kept");
        assert_eq!(mode(&cancelled), 0o600);
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn decodes_right_ctrl_press_and_skips_sync() {
        let mut b = [0u8; 24];
        b[16..18].copy_from_slice(&EV_KEY.to_ne_bytes());
        b[18..20].copy_from_slice(&KEY_RIGHTCTRL.to_ne_bytes());
        b[20..24].copy_from_slice(&1i32.to_ne_bytes());
        assert_eq!(key_event(&b), Some((97, 1)));
        b[16..18].copy_from_slice(&0u16.to_ne_bytes()); // EV_SYN
        assert_eq!(key_event(&b), None);
    }

    #[test]
    fn default_hotkey_is_right_ctrl() {
        assert_eq!(parse_key("RightCtrl"), Some(97));
        assert_eq!(parse_key("58"), Some(58));
        assert_eq!(parse_key("fn"), None);
    }
}
