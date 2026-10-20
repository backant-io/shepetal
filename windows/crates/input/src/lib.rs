//! shepetal for Windows: the hotkey hook, the 🤫 overlay and the tray icon.
//!
//! The pure parts live here and build and test on any OS: hotkey parsing and chord tracking,
//! the overlay's position for any monitor and DPI, the state-to-colour mapping, the pulse and
//! the hint timing. The Win32 side (`spawn`, `Ui`) only builds on Windows.

#[cfg(windows)]
mod win;
#[cfg(windows)]
pub use win::{spawn, Ui};

use std::time::Instant;

pub const VK_TAB: u16 = 0x09;
pub const VK_SHIFT: u16 = 0x10;
pub const VK_CONTROL: u16 = 0x11;
pub const VK_MENU: u16 = 0x12;
pub const VK_CAPITAL: u16 = 0x14;
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_SPACE: u16 = 0x20;
/// Either Win key; the right one (VK_RWIN) is folded into it.
pub const VK_LWIN: u16 = 0x5B;
/// An unassigned key code. Pressing it while the hotkey holds Win or Alt makes Windows treat that
/// key as used in a chord, so its release does not open the Start menu or a menu bar (which would
/// steal focus and send every dictation to the clipboard, rule 8). AutoHotkey uses the same code.
pub const MASK_VK: u16 = 0xE8;

/// What the input thread reports to the app.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    Key(KeyEvent, Instant),
    /// Tray menu: Open.
    Open,
    /// Tray menu: Pause was toggled; `true` means now paused.
    Pause(bool),
    /// Tray menu: Start at login was clicked. The app flips the setting, then calls
    /// `Ui::set_start_at_login` so the check mark follows.
    StartAtLogin,
    /// Tray menu: Quit. The tray icon, overlay and hook are already gone.
    Quit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    pub key: Key,
    pub down: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    /// Every key of the hotkey went down, or one of them came up.
    Hotkey,
    Esc,
    /// Another key went down while the hotkey was held (the Windows VK code), so a chord such as
    /// Ctrl+Win+D can cancel. Only downs, and only while the hotkey is held: normal typing is
    /// never reported.
    Other(u16),
}

/// A hotkey: one to three keys that must all be held, as Windows VK codes. Left and right
/// modifiers count as the same key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hotkey(Vec<u16>);

impl Default for Hotkey {
    /// Ctrl+Win, Wispr Flow's Windows push-to-talk default (docs/re/dictation-input.md).
    fn default() -> Self {
        Hotkey(vec![VK_CONTROL, VK_LWIN])
    }
}

impl Hotkey {
    /// Parses names joined by `+`: Ctrl, Shift, Alt, Win, Space, Tab, CapsLock, A-Z, 0-9, F1-F24.
    pub fn parse(s: &str) -> Result<Hotkey, String> {
        let mut keys = Vec::new();
        for name in s.split('+') {
            let n = name.trim().to_ascii_lowercase();
            let vk = match n.as_str() {
                "ctrl" | "control" => VK_CONTROL,
                "shift" => VK_SHIFT,
                "alt" => VK_MENU,
                "win" | "super" => VK_LWIN,
                "space" => VK_SPACE,
                "tab" => VK_TAB,
                "capslock" => VK_CAPITAL,
                _ if n.len() == 1 && n.as_bytes()[0].is_ascii_alphanumeric() => {
                    n.as_bytes()[0].to_ascii_uppercase() as u16
                }
                _ => match n.strip_prefix('f').and_then(|i| i.parse::<u16>().ok()) {
                    Some(i @ 1..=24) => 0x6F + i, // VK_F1 is 0x70
                    _ => return Err(format!("unknown key {:?} in hotkey {s:?}", name.trim())),
                },
            };
            if keys.contains(&vk) {
                return Err(format!("{:?} is listed twice in hotkey {s:?}", name.trim()));
            }
            keys.push(vk);
        }
        if keys.len() > 3 {
            return Err(format!("hotkey {s:?} has more than 3 keys"));
        }
        Ok(Hotkey(keys))
    }

    /// Whether releasing it could open the Start menu or a menu bar (see `MASK_VK`).
    pub fn needs_mask(&self) -> bool {
        self.0.iter().any(|&k| k == VK_LWIN || k == VK_MENU)
    }
}

/// Folds left/right variants into one code: VK_LSHIFT -> VK_SHIFT, VK_RWIN -> VK_LWIN, ...
fn canonical(vk: u16) -> u16 {
    match vk {
        0xA0 | 0xA1 => VK_SHIFT,
        0xA2 | 0xA3 => VK_CONTROL,
        0xA4 | 0xA5 => VK_MENU,
        0x5C => VK_LWIN,
        v => v,
    }
}

/// Turns raw key downs and ups (auto-repeat included) into hotkey and Esc events. Pure; the hook
/// feeds it every key and passes every key on.
#[derive(Debug, Default)]
pub struct Chord {
    hotkey: Hotkey,
    /// Raw VK codes of hotkey keys that are down.
    held: Vec<u16>,
    active: bool,
    esc: bool,
}

impl Chord {
    pub fn new(hotkey: Hotkey) -> Chord {
        Chord {
            hotkey,
            ..Chord::default()
        }
    }

    pub fn hotkey(&self) -> &Hotkey {
        &self.hotkey
    }

    pub fn feed(&mut self, vk: u16, down: bool) -> Option<KeyEvent> {
        if vk == MASK_VK {
            return None; // our own mask key
        }
        if vk == VK_ESCAPE {
            if self.esc == down {
                return None; // auto-repeat, or an up whose down we never saw
            }
            self.esc = down;
            return Some(KeyEvent {
                key: Key::Esc,
                down,
            });
        }
        if !self.hotkey.0.contains(&canonical(vk)) {
            return (down && self.active).then_some(KeyEvent {
                key: Key::Other(vk),
                down: true,
            });
        }
        if !down {
            self.held.retain(|&h| h != vk);
        } else if !self.held.contains(&vk) {
            self.held.push(vk);
        }
        let all = self
            .hotkey
            .0
            .iter()
            .all(|&k| self.held.iter().any(|&h| canonical(h) == k));
        if all == self.active {
            return None;
        }
        self.active = all;
        Some(KeyEvent {
            key: Key::Hotkey,
            down: all,
        })
    }

    /// Releases keys we think are down but `is_down` says are up. Windows drops key-ups when the
    /// hook was removed or the secure desktop took them (Ctrl+Alt+Del, Win+L); without this the
    /// hotkey would look held forever and never start again.
    pub fn release_stale(&mut self, is_down: impl Fn(u16) -> bool) -> Vec<KeyEvent> {
        let mut stale: Vec<u16> = self
            .held
            .iter()
            .copied()
            .filter(|&vk| !is_down(vk))
            .collect();
        if self.esc && !is_down(VK_ESCAPE) {
            stale.push(VK_ESCAPE);
        }
        stale
            .into_iter()
            .filter_map(|vk| self.feed(vk, false))
            .collect()
    }
}

/// What the 🤫 indicator shows, as on the Mac (Sources/Shepetal/Indicator.swift).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Mode {
    #[default]
    Idle,
    Recording,
    HandsFree,
    Processing,
    Error,
}

/// Ring colour (sRGB) per mode: the Apple system colours the Mac indicator uses.
pub fn ring_color(mode: Mode) -> Option<[u8; 3]> {
    match mode {
        Mode::Idle => None,
        Mode::Recording => Some([0xFF, 0x3B, 0x30]),
        Mode::HandsFree => Some([0xFF, 0x95, 0x00]),
        Mode::Processing => Some([0x00, 0x7A, 0xFF]),
        Mode::Error => Some([0xFF, 0xCC, 0x00]),
    }
}

/// One fade of the processing pulse, as on the Mac (0.6 s each way, opacity 1 -> 0.35).
pub const PULSE_MS: u64 = 600;
pub const PULSE_MIN: f32 = 0.35;

/// Ring opacity `ms` after the mode was set: processing fades linearly 1 -> 0.35 -> 1, every
/// other mode is solid.
pub fn ring_alpha(mode: Mode, ms: u64) -> f32 {
    if mode != Mode::Processing {
        return 1.0;
    }
    let phase = (ms % (2 * PULSE_MS)) as f32 / PULSE_MS as f32; // 0..2
    let t = if phase <= 1.0 { phase } else { 2.0 - phase };
    1.0 - (1.0 - PULSE_MIN) * t
}

/// How long a hint stays next to 🤫 (product rule 2: about 2 s).
pub const HINT_MS: u64 = 2000;

/// The indicator's state over time. Pure: times are milliseconds on any monotonic clock.
#[derive(Debug, Default)]
pub struct View {
    mode: Mode,
    since: u64,
    hint: Option<(String, u64)>,
}

/// What to draw at one instant.
#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    /// Ring colour and opacity, if any.
    pub ring: Option<([u8; 3], f32)>,
    pub label: Option<String>,
}

impl View {
    pub fn set_mode(&mut self, mode: Mode, now: u64) {
        if mode != self.mode {
            self.mode = mode;
            self.since = now;
        }
    }

    /// Shows `text` for `ms`, replacing any hint still showing (its timer restarts).
    pub fn show_hint(&mut self, text: &str, ms: u64, now: u64) {
        self.hint = Some((text.to_string(), now + ms));
    }

    pub fn frame(&self, now: u64) -> Frame {
        Frame {
            ring: ring_color(self.mode).map(|c| (c, ring_alpha(self.mode, now - self.since))),
            label: self
                .hint
                .as_ref()
                .filter(|h| now < h.1)
                .map(|h| h.0.clone()),
        }
    }

    /// Whether the frame can change without another call: a pulse, or a hint still to hide.
    pub fn animating(&self, now: u64) -> bool {
        self.mode == Mode::Processing || self.hint.as_ref().is_some_and(|h| now < h.1)
    }
}

/// A rectangle in physical pixels, Win32 RECT style (right and bottom exclusive).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

/// The indicator's size, inset from the corner, and gap to the hint label, at 100% scale.
pub const SIZE: i32 = 18;
pub const INSET: i32 = 8;
pub const GAP: i32 = 6;

/// `px` at 100% scale (96 DPI) in pixels at `dpi`, rounded to nearest.
pub fn scale(px: i32, dpi: u32) -> i32 {
    (px * dpi as i32 + 48) / 96
}

/// The overlay window for a monitor whose work area (the monitor minus the taskbar) is `work`:
/// the 🤫 square inset from its bottom-left corner, plus `label_w` pixels of hint label to the
/// right when a hint shows.
pub fn overlay_rect(work: Rect, dpi: u32, label_w: i32) -> Rect {
    let (size, inset) = (scale(SIZE, dpi), scale(INSET, dpi));
    let width = if label_w > 0 {
        size + scale(GAP, dpi) + label_w
    } else {
        size
    };
    let (left, bottom) = (work.left + inset, work.bottom - inset);
    Rect {
        left,
        top: bottom - size,
        right: left + width,
        bottom,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LCTRL: u16 = 0xA2;
    const RCTRL: u16 = 0xA3;
    const RWIN: u16 = 0x5C;

    fn hot(down: bool) -> Option<KeyEvent> {
        Some(KeyEvent {
            key: Key::Hotkey,
            down,
        })
    }

    #[test]
    fn hotkey_fires_once_both_keys_are_down_in_either_order() {
        let mut c = Chord::new(Hotkey::default());
        assert_eq!(c.feed(LCTRL, true), None, "Ctrl alone is just Ctrl");
        assert_eq!(c.feed(VK_LWIN, true), hot(true));
        let mut c = Chord::new(Hotkey::default());
        assert_eq!(c.feed(RWIN, true), None);
        assert_eq!(c.feed(RCTRL, true), hot(true), "right-hand keys count too");
    }

    #[test]
    fn auto_repeat_does_not_restart_the_hotkey() {
        // Windows repeats the last key's down while held; a second Down would read as a double tap.
        let mut c = Chord::new(Hotkey::default());
        c.feed(LCTRL, true);
        assert_eq!(c.feed(VK_LWIN, true), hot(true));
        for _ in 0..5 {
            assert_eq!(c.feed(VK_LWIN, true), None);
        }
        assert_eq!(c.feed(VK_LWIN, false), hot(false));
        assert_eq!(c.feed(LCTRL, false), None, "already up");
    }

    #[test]
    fn hotkey_stays_held_while_the_other_ctrl_is_still_down() {
        let mut c = Chord::new(Hotkey::default());
        c.feed(LCTRL, true);
        c.feed(RCTRL, true);
        c.feed(VK_LWIN, true);
        assert_eq!(c.feed(LCTRL, false), None);
        assert_eq!(c.feed(RCTRL, false), hot(false));
    }

    #[test]
    fn other_keys_are_reported_only_while_the_hotkey_is_held() {
        let mut c = Chord::new(Hotkey::default());
        assert_eq!(c.feed(0x41, true), None, "plain typing is never reported");
        c.feed(LCTRL, true);
        assert_eq!(c.feed(0x44, true), None, "Ctrl+D is not ours");
        c.feed(VK_LWIN, true);
        assert_eq!(
            c.feed(0x44, true),
            Some(KeyEvent {
                key: Key::Other(0x44),
                down: true
            })
        );
        assert_eq!(c.feed(0x44, false), None);
    }

    #[test]
    fn our_mask_key_is_not_a_chord() {
        let mut c = Chord::new(Hotkey::default());
        c.feed(LCTRL, true);
        c.feed(VK_LWIN, true);
        assert_eq!(
            c.feed(MASK_VK, true),
            None,
            "else every dictation would cancel itself"
        );
        assert_eq!(c.feed(MASK_VK, false), None);
    }

    #[test]
    fn esc_reports_down_and_up_once() {
        let mut c = Chord::new(Hotkey::default());
        assert_eq!(c.feed(VK_ESCAPE, false), None, "an up whose down we missed");
        assert_eq!(
            c.feed(VK_ESCAPE, true),
            Some(KeyEvent {
                key: Key::Esc,
                down: true
            })
        );
        assert_eq!(c.feed(VK_ESCAPE, true), None);
        assert_eq!(
            c.feed(VK_ESCAPE, false),
            Some(KeyEvent {
                key: Key::Esc,
                down: false
            })
        );
    }

    #[test]
    fn a_lost_key_up_is_released_so_the_hotkey_works_again() {
        // Ctrl+Win+L locks the screen; the ups go to the lock screen, not to our hook.
        let mut c = Chord::new(Hotkey::default());
        c.feed(LCTRL, true);
        c.feed(VK_LWIN, true);
        c.feed(VK_ESCAPE, true);
        assert_eq!(
            c.release_stale(|vk| vk == LCTRL),
            vec![
                KeyEvent {
                    key: Key::Hotkey,
                    down: false
                },
                KeyEvent {
                    key: Key::Esc,
                    down: false
                },
            ]
        );
        assert_eq!(
            c.release_stale(|_| false),
            vec![],
            "Ctrl's release is no event of its own"
        );
        c.feed(LCTRL, true);
        assert_eq!(c.feed(VK_LWIN, true), hot(true));
        assert_eq!(
            c.release_stale(|_| true),
            vec![],
            "keys really down stay down"
        );
    }

    #[test]
    fn hotkey_parsing() {
        assert_eq!(Hotkey::parse("Ctrl+Win"), Ok(Hotkey::default()));
        assert_eq!(
            Hotkey::parse(" ctrl + win + space "),
            Ok(Hotkey(vec![VK_CONTROL, VK_LWIN, VK_SPACE]))
        );
        assert_eq!(Hotkey::parse("Alt+F12"), Ok(Hotkey(vec![VK_MENU, 0x7B])));
        assert_eq!(Hotkey::parse("CapsLock"), Ok(Hotkey(vec![VK_CAPITAL])));
        assert_eq!(Hotkey::parse("Shift+a"), Ok(Hotkey(vec![VK_SHIFT, 0x41])));
        assert!(
            Hotkey::parse("Ctrl+Shift+Alt+Win").is_err(),
            "at most 3 keys"
        );
        assert!(Hotkey::parse("Ctrl+ctrl").is_err());
        assert!(Hotkey::parse("Ctrl+Hyper").is_err());
        assert!(Hotkey::parse("F25").is_err());
        assert!(Hotkey::parse("").is_err());
    }

    #[test]
    fn mask_only_for_keys_whose_release_opens_a_menu() {
        assert!(Hotkey::default().needs_mask(), "Win opens Start");
        assert!(
            Hotkey::parse("Ctrl+Alt").unwrap().needs_mask(),
            "Alt opens the menu bar"
        );
        assert!(!Hotkey::parse("Ctrl+Shift").unwrap().needs_mask());
    }

    #[test]
    fn overlay_sits_above_the_taskbar_in_the_bottom_left() {
        // 1920x1080 primary, 48 px taskbar at the bottom: work area ends at 1032.
        let work = Rect {
            left: 0,
            top: 0,
            right: 1920,
            bottom: 1032,
        };
        assert_eq!(
            overlay_rect(work, 96, 0),
            Rect {
                left: 8,
                top: 1006,
                right: 26,
                bottom: 1024
            }
        );
    }

    #[test]
    fn overlay_scales_with_dpi() {
        let work = Rect {
            left: 0,
            top: 0,
            right: 2560,
            bottom: 1368,
        };
        // 150%: 27 px square, 12 px inset.
        assert_eq!(
            overlay_rect(work, 144, 0),
            Rect {
                left: 12,
                top: 1329,
                right: 39,
                bottom: 1356
            }
        );
        // 200%: 36 px, 16 px. 125%: 22.5 rounds to 23, 10 px.
        assert_eq!(
            overlay_rect(work, 192, 0),
            Rect {
                left: 16,
                top: 1316,
                right: 52,
                bottom: 1352
            }
        );
        assert_eq!(
            overlay_rect(work, 120, 0),
            Rect {
                left: 10,
                top: 1335,
                right: 33,
                bottom: 1358
            }
        );
    }

    #[test]
    fn overlay_follows_the_work_area_on_any_monitor() {
        // Taskbar on the left, and a monitor left of the primary (negative coordinates).
        let left_bar = Rect {
            left: 62,
            top: 0,
            right: 1920,
            bottom: 1080,
        };
        assert_eq!(overlay_rect(left_bar, 96, 0).left, 70);
        let west = Rect {
            left: -1280,
            top: -200,
            right: 0,
            bottom: 824,
        };
        assert_eq!(
            overlay_rect(west, 96, 0),
            Rect {
                left: -1272,
                top: 798,
                right: -1254,
                bottom: 816
            }
        );
    }

    #[test]
    fn hint_label_widens_the_window_to_the_right_only() {
        let work = Rect {
            left: 0,
            top: 0,
            right: 1920,
            bottom: 1032,
        };
        let bare = overlay_rect(work, 96, 0);
        let hinted = overlay_rect(work, 96, 100);
        assert_eq!(
            (hinted.left, hinted.top, hinted.bottom),
            (bare.left, bare.top, bare.bottom)
        );
        assert_eq!(hinted.right, bare.right + GAP + 100);
    }

    #[test]
    fn every_active_mode_has_its_own_ring() {
        assert_eq!(ring_color(Mode::Idle), None, "idle is the bare emoji");
        let modes = [
            Mode::Recording,
            Mode::HandsFree,
            Mode::Processing,
            Mode::Error,
        ];
        let colours: Vec<_> = modes
            .iter()
            .map(|&m| ring_color(m).expect("ring"))
            .collect();
        for (i, a) in colours.iter().enumerate() {
            assert!(
                colours[i + 1..].iter().all(|b| a != b),
                "modes must be told apart"
            );
        }
        assert_eq!(ring_color(Mode::Recording), Some([0xFF, 0x3B, 0x30]), "red");
        assert_eq!(
            ring_color(Mode::Processing),
            Some([0x00, 0x7A, 0xFF]),
            "blue"
        );
    }

    #[test]
    fn only_processing_pulses() {
        assert_eq!(ring_alpha(Mode::Recording, 300), 1.0);
        assert_eq!(ring_alpha(Mode::Processing, 0), 1.0);
        assert!((ring_alpha(Mode::Processing, 300) - 0.675).abs() < 1e-6);
        assert!((ring_alpha(Mode::Processing, PULSE_MS) - PULSE_MIN).abs() < 1e-6);
        assert!(
            (ring_alpha(Mode::Processing, 900) - 0.675).abs() < 1e-6,
            "fades back"
        );
        assert_eq!(
            ring_alpha(Mode::Processing, 2 * PULSE_MS),
            1.0,
            "and repeats"
        );
    }

    #[test]
    fn hint_shows_for_its_time_and_a_new_one_restarts_it() {
        let mut v = View::default();
        v.show_hint("Hold Ctrl+Win to talk", HINT_MS, 1000);
        assert_eq!(
            v.frame(1000).label.as_deref(),
            Some("Hold Ctrl+Win to talk")
        );
        assert!(v.animating(2999));
        v.show_hint("Copied, press Ctrl+V", HINT_MS, 2500);
        assert_eq!(
            v.frame(3500).label.as_deref(),
            Some("Copied, press Ctrl+V"),
            "old timer is gone"
        );
        assert_eq!(v.frame(4499).label.as_deref(), Some("Copied, press Ctrl+V"));
        assert_eq!(v.frame(4500).label, None);
        assert!(
            !v.animating(4500),
            "nothing left to redraw, the timer can stop"
        );
    }

    #[test]
    fn pulse_starts_when_processing_starts() {
        let mut v = View::default();
        v.set_mode(Mode::Processing, 5000);
        assert_eq!(
            v.frame(5000).ring,
            Some(([0x00, 0x7A, 0xFF], 1.0)),
            "starts solid, not mid-fade"
        );
        v.set_mode(Mode::Processing, 5300);
        assert!(
            (v.frame(5300).ring.unwrap().1 - 0.675).abs() < 1e-6,
            "re-setting keeps the phase"
        );
        assert!(v.animating(9000));
        v.set_mode(Mode::Idle, 9000);
        assert_eq!(
            v.frame(9000),
            Frame {
                ring: None,
                label: None
            }
        );
        assert!(!v.animating(9000));
    }
}
