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

#[cfg(test)]
mod tests {
    use super::*;

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
