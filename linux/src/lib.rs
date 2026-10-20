use std::path::{Path, PathBuf};

pub mod focus;
pub mod gesture;
pub mod indicator;
pub mod insert;
pub mod meeting;
pub mod mic;
pub mod model;
pub mod text_rules;
pub mod vocab;

pub const EV_KEY: u16 = 1;
/// evdev KEY_FN (0x1d0), the default hotkey. Apple keyboards send it through hid-apple.
pub const KEY_FN: u16 = 464;

/// Decode one `struct input_event` (64-bit layout: timeval 16 bytes, type u16, code u16, value i32)
/// into (code, value) if it is a key event. value: 1 down, 0 up, 2 autorepeat.
pub fn key_event(buf: &[u8; 24]) -> Option<(u16, i32)> {
    let ty = u16::from_ne_bytes([buf[16], buf[17]]);
    let code = u16::from_ne_bytes([buf[18], buf[19]]);
    let value = i32::from_ne_bytes([buf[20], buf[21], buf[22], buf[23]]);
    (ty == EV_KEY).then_some((code, value))
}

/// The dictation hotkey: `SHEPETAL_KEY` when set, else fn.
pub fn hotkey(shepetal_key: Option<&str>) -> Option<u16> {
    shepetal_key.map_or(Some(KEY_FN), parse_key)
}

/// Whether `code` is set in a sysfs `capabilities/key` bitmap. The kernel (input_print_bitmap)
/// prints unsigned longs as unpadded hex, most significant word first, separated by spaces,
/// drops leading zero words and prints a single "0" for an empty map. A 32-bit process on a
/// 64-bit kernel gets 32-bit words (input_bits_to_string), so a word is this process's usize.
pub fn has_key(bitmap: &str, code: u16) -> bool {
    let (word, bit) = (code as usize / usize::BITS as usize, code as u32 % usize::BITS);
    bitmap.split_whitespace().rev().nth(word)
        .and_then(|w| usize::from_str_radix(w, 16).ok())
        .is_some_and(|w| w >> bit & 1 == 1)
}

/// Hotkey from a name or a raw evdev code (see linux/input-event-codes.h).
pub fn parse_key(s: &str) -> Option<u16> {
    match s.to_ascii_lowercase().as_str() {
        "fn" => Some(KEY_FN),
        "rightctrl" => Some(97),
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

/// Every recording is kept. A cancelled or too-short one is renamed `<stamp>.<label>.wav`
/// (`cancelled`, `tooshort`), never deleted.
pub fn mark(wav: &Path, label: &str) -> std::io::Result<PathBuf> {
    let to = wav.with_extension(format!("{label}.wav"));
    std::fs::rename(wav, &to)?;
    Ok(to)
}

/// Shown next to the 🤫 indicator after a too-short press. Our own wording, as on the Mac.
pub fn short_press_hint(key: &str) -> String {
    format!("Hold {key} to talk · double-tap for hands-free")
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
        let cancelled = mark(&wav, "cancelled").unwrap();
        assert_eq!(cancelled.file_name().unwrap(), "1.cancelled.wav");
        assert_eq!(std::fs::read(&cancelled).unwrap(), b"RIFF", "cancelled audio must be kept");
        assert_eq!(mode(&cancelled), 0o600);
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn an_audio_dir_open_to_others_is_refused() {
        // Goal rule 4: owner-only. An existing dir that others can read is not used as is.
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("shepetal-open-{}", std::process::id()));
        let dir = home.join("shepetal/audio");
        std::fs::create_dir_all(&dir).unwrap();
        for mode in [0o755, 0o750, 0o705] {
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(mode)).unwrap();
            let err = new_recording(&home, 1).unwrap_err();
            assert!(err.to_string().contains("must be a 0700 directory"), "{mode:o}: {err}");
        }
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0, "no file created in it");
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn decodes_fn_press_and_skips_sync() {
        let mut b = [0u8; 24];
        b[16..18].copy_from_slice(&EV_KEY.to_ne_bytes());
        b[18..20].copy_from_slice(&KEY_FN.to_ne_bytes());
        b[20..24].copy_from_slice(&1i32.to_ne_bytes());
        assert_eq!(key_event(&b), Some((0x1d0, 1)));
        b[16..18].copy_from_slice(&0u16.to_ne_bytes()); // EV_SYN
        assert_eq!(key_event(&b), None);
    }

    #[test]
    fn default_hotkey_is_fn() {
        // Pavel's decision: dictation starts with fn on Linux too. 0x1d0 is KEY_FN in
        // linux/input-event-codes.h; any other default breaks this test.
        assert_eq!(hotkey(None), Some(0x1d0));
        assert_eq!(parse_key("FN"), Some(0x1d0));
        assert_eq!(hotkey(Some("rightalt")), Some(100), "SHEPETAL_KEY overrides the default");
        assert_eq!(hotkey(Some("58")), Some(58));
        assert_eq!(hotkey(Some("nope")), None, "a typo must not fall back to fn");
    }

    // `capabilities/key` text with 64-bit words. LAPTOP: a common AT Translated Set 2 keyboard,
    // whose fn is handled by firmware. APPLE is computed, not captured: a generic USB keyboard
    // plus the bits hid-apple v7.3 sets (KEY_FN, KEY_NUMLOCK and its fn translation targets).
    const APPLE: &str = "10000 0 0 0 101007b02001007 ff9f207ac14057ff ffbeffdfffefffff fffffffffffffffe\n";
    const LAPTOP: &str = "402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe\n";
    // Power Button, read from /sys/class/input/event0 in Docker Desktop's Linux VM.
    const POWER_BUTTON: &str = "8000 10000000000000 0\n";

    #[test]
    fn fn_is_bit_464_of_the_sysfs_key_bitmap() {
        assert!(has_key(APPLE, KEY_FN));
        assert!(!has_key(APPLE, KEY_FN - 1), "off by one");
        assert!(!has_key(APPLE, KEY_FN + 1), "off by one");
        assert!(!has_key(LAPTOP, KEY_FN), "laptop firmware eats fn");
    }

    #[test]
    fn last_word_holds_bit_0() {
        // The kernel prints the highest word first. Read the other way round, ESC (1) would
        // come from "10000" and be false.
        assert!(has_key(APPLE, 1));
        assert!(!has_key(APPLE, 0));
        assert!(has_key(LAPTOP, 97)); // Right Ctrl, bit 33 of the second-to-last word
        assert!(!has_key(LAPTOP, 101)); // KEY_LINEFEED is not on this map; reversed it is
    }

    #[test]
    fn leading_zero_words_are_dropped() {
        assert!(has_key(POWER_BUTTON, 116)); // KEY_POWER, word 1
        assert!(has_key(POWER_BUTTON, 143)); // KEY_WAKEUP, word 2
        assert!(!has_key(POWER_BUTTON, KEY_FN), "missing words are zero, not an error");
        assert!(!has_key("0\n", 0));
        assert!(!has_key("0", KEY_FN));
        assert!(!has_key("", KEY_FN));
    }
}
