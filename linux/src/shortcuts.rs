//! The keys besides the dictation hotkey, and the length cap (20 min unless config.json says). Pure: feed it evdev key events
//! (code, value) with millisecond timestamps. It owns the hotkey's `Gesture` too, so a recording
//! started by either path has one owner.
//!
//! - Esc cancels a running dictation. Its audio is kept as `*.cancelled.wav` (goal rule 4).
//!   With nothing recording Esc does nothing. shepetal reads evdev without a grab, so no key,
//!   Esc included, is ever swallowed: the focused app always gets it.
//! - paste-last and copy-last (Wispr's Windows defaults Shift+Alt+Z and Shift+Alt+X) fire once
//!   every key is up, so the held Shift and Alt do not change the typed text.
//! - A dedicated hands-free toggle (Wispr's Windows default Ctrl+Win+Space): one press starts,
//!   the next stops, a second press within 500 ms of the start cancels. The hotkey stops it too.
//! - A warning one minute before the cap and a stop (transcribed as usual) at the cap: 19 and
//!   20 min by default, as Wispr (docs/re/dictation-input.md, section 2.3). The cap is a setting,
//!   as on the Mac (`maxDictationMinutes`).
//!
//! The combos and the cap live in `~/.config/shepetal/config.json`, the one settings file of the
//! daemon:
//!
//! ```json
//! {"shortcuts": {"paste_last": "shift+alt+z", "copy_last": "shift+alt+x", "hands_free": "ctrl+meta+space"},
//!  "dictation": {"max_minutes": 20}}
//! ```

use crate::gesture::{Action, Event, Gesture, DOUBLE_TAP_MS};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

pub const KEY_ESC: u16 = 1;
/// The default cap, and how long before the cap the warning comes.
pub const MAX_MS: u64 = 20 * 60_000;
pub const WARN_LEAD_MS: u64 = 60_000;
/// The longest cap config.json may set: a day.
const MAX_MINUTES: u64 = 24 * 60;
/// Shown next to 🤫 and as a desktop notification one minute before the cap. Our own wording.
pub const WARNING: &str = "Recording stops in 1 minute";

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Cmd {
    Dictation(Action),
    MaxLengthWarning,
    PasteLast,
    CopyLast,
}

/// A key combo: per key, the evdev codes that count as it ("alt" is Left Alt or Right Alt).
/// The modifiers come first and the one other key last.
#[derive(Debug, Clone, PartialEq)]
pub struct Combo(Vec<Vec<u16>>);

impl Combo {
    /// Exactly these keys are held and `pressed` is the non-modifier key, as in any chord.
    fn matches(&self, held: &BTreeSet<u16>, pressed: u16) -> bool {
        held.len() == self.0.len()
            && self.0.last().is_some_and(|k| k.contains(&pressed))
            && self.0.iter().all(|k| k.iter().any(|c| held.contains(c)))
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    pub paste_last: Combo,
    pub copy_last: Combo,
    pub hands_free: Combo,
    /// The length cap: a dictation is stopped and transcribed when it has run this long.
    pub max_ms: u64,
}

pub const DEFAULTS: [(&str, &str); 3] = [
    ("paste_last", "shift+alt+z"),
    ("copy_last", "shift+alt+x"),
    ("hands_free", "ctrl+meta+space"),
];

/// Modifier names: the codes each stands for, and the family that may appear once per combo.
fn modifier(name: &str) -> Option<(&'static [u16], &'static str)> {
    Some(match name {
        "ctrl" => (&[29, 97], "ctrl"),
        "leftctrl" => (&[29], "ctrl"),
        "rightctrl" => (&[97], "ctrl"),
        "shift" => (&[42, 54], "shift"),
        "leftshift" => (&[42], "shift"),
        "rightshift" => (&[54], "shift"),
        "alt" => (&[56, 100], "alt"),
        "leftalt" => (&[56], "alt"),
        "rightalt" => (&[100], "alt"),
        "meta" | "super" | "win" => (&[125, 126], "meta"),
        "leftmeta" => (&[125], "meta"),
        "rightmeta" => (&[126], "meta"),
        _ => return None,
    })
}

/// A non-modifier key by name (linux/input-event-codes.h) or raw evdev code.
fn key(name: &str) -> Option<u16> {
    const LETTERS: &str = "qwertyuiop    asdfghjkl     zxcvbnm";
    if let [c] = name.as_bytes() {
        if c.is_ascii_lowercase() {
            return LETTERS.find(*c as char).map(|i| 16 + i as u16);
        }
        if c.is_ascii_digit() {
            return Some(if *c == b'0' { 11 } else { (c - b'0') as u16 + 1 });
        }
    }
    if let Some(n) = name.strip_prefix('f').and_then(|n| n.parse::<u16>().ok()) {
        return match n {
            1..=10 => Some(58 + n),
            11 | 12 => Some(76 + n),
            13..=24 => Some(170 + n),
            _ => None,
        };
    }
    Some(match name {
        "esc" => KEY_ESC,
        "space" => 57,
        "tab" => 15,
        "enter" => 28,
        "backspace" => 14,
        "insert" => 110,
        "delete" => 111,
        "home" => 102,
        "end" => 107,
        "pageup" => 104,
        "pagedown" => 109,
        "up" => 103,
        "down" => 108,
        "left" => 105,
        "right" => 106,
        "capslock" => 58,
        "fn" => crate::KEY_FN,
        n => return n.parse().ok(),
    })
}

/// Parse and validate one combo, as Wispr's shortcut editor does: at most 3 keys, a modifier
/// and one other key, each modifier once (no Left Alt + Right Alt), and nothing the dictation
/// hotkey sends. A generic modifier ("alt") skips the side that is the hotkey, so the default
/// Shift+Alt+Z still works with SHEPETAL_KEY=rightalt, through Left Alt.
pub fn combo(s: &str, hotkey: u16) -> Result<Combo, String> {
    let names: Vec<String> = s.split('+').map(|k| k.trim().to_ascii_lowercase()).collect();
    if names.len() > 3 {
        return Err(format!("{s:?} has {} keys, at most 3 are allowed", names.len()));
    }
    let (mut keys, mut families, mut others) = (vec![], vec![], vec![]);
    for n in &names {
        let codes: Vec<u16> = match modifier(n) {
            Some((codes, family)) => {
                if families.contains(&family) {
                    return Err(format!("{s:?} uses {family} twice"));
                }
                families.push(family);
                codes.to_vec()
            }
            None => vec![key(n).ok_or(format!("{s:?}: unknown key {n:?}"))?],
        };
        if codes.contains(&KEY_ESC) {
            return Err(format!("{s:?} uses Esc, which cancels a dictation"));
        }
        let codes: Vec<u16> = codes.into_iter().filter(|&c| c != hotkey).collect();
        if codes.is_empty() {
            return Err(format!("{s:?} uses {n}, the dictation hotkey"));
        }
        match modifier(n) {
            Some(_) => keys.push(codes),
            None => others.push(codes),
        }
    }
    if families.is_empty() {
        return Err(format!("{s:?} needs a modifier: ctrl, alt, shift or meta"));
    }
    if others.len() != 1 {
        return Err(format!("{s:?} needs exactly one key besides the modifiers"));
    }
    keys.append(&mut others);
    Ok(Combo(keys))
}

/// `$XDG_CONFIG_HOME/shepetal/config.json`, else `~/.config/shepetal/config.json`. A relative
/// XDG_CONFIG_HOME is ignored, as the XDG Base Directory spec says.
pub fn config_file(xdg_config_home: Option<&str>, home: &str) -> PathBuf {
    let base = match xdg_config_home {
        Some(d) if d.starts_with('/') => PathBuf::from(d),
        _ => Path::new(home).join(".config"),
    };
    base.join("shepetal").join("config.json")
}

/// Read the `shortcuts` and `dictation` objects of config.json (an empty or missing file means
/// the defaults). Other keys belong to other features and are skipped; an unknown name in either
/// object is an error, so a typo is not silently ignored.
pub fn parse(json: &str, hotkey: u16) -> Result<Config, String> {
    let mut vals = DEFAULTS.map(|(k, v)| (k, v.to_string()));
    let v: serde_json::Value = if json.trim().is_empty() { Default::default() } else { serde_json::from_str(json).map_err(|e| e.to_string())? };
    if let Some(set) = v.get("shortcuts") {
        for (k, val) in set.as_object().ok_or("\"shortcuts\" must be an object")? {
            let slot = vals.iter_mut().find(|(name, _)| name == k)
                .ok_or(format!("unknown shortcut {k:?} (paste_last, copy_last, hands_free)"))?;
            slot.1 = val.as_str().ok_or(format!("{k}: expected keys as a string, such as \"shift+alt+z\""))?.to_string();
        }
    }
    let mut combos: Vec<(&str, Combo)> = vec![];
    for (name, v) in &vals {
        let c = combo(v, hotkey).map_err(|e| format!("{name}: {e}"))?;
        if let Some((other, _)) = combos.iter().find(|(_, o)| same_keys(o, &c)) {
            return Err(format!("{name}: {v:?} is already {other}"));
        }
        combos.push((*name, c));
    }
    let mut it = combos.into_iter().map(|(_, c)| c);
    let mut next = || it.next().unwrap();
    Ok(Config { paste_last: next(), copy_last: next(), hands_free: next(), max_ms: max_ms(&v)? })
}

/// `dictation.max_minutes`: whole minutes from 1 to a day, else the 20 min default.
fn max_ms(v: &serde_json::Value) -> Result<u64, String> {
    let Some(d) = v.get("dictation") else { return Ok(MAX_MS) };
    let d = d.as_object().ok_or("\"dictation\" must be an object")?;
    if let Some(k) = d.keys().find(|k| *k != "max_minutes") {
        return Err(format!("unknown dictation setting {k:?} (max_minutes)"));
    }
    match d.get("max_minutes") {
        None => Ok(MAX_MS),
        Some(m) => match m.as_u64() {
            Some(n @ 1..=MAX_MINUTES) => Ok(n * 60_000),
            _ => Err(format!("dictation.max_minutes: expected whole minutes from 1 to {MAX_MINUTES}, got {m}")),
        },
    }
}

fn same_keys(a: &Combo, b: &Combo) -> bool {
    let sorted = |c: &Combo| c.0.iter().cloned().collect::<BTreeSet<_>>();
    sorted(a) == sorted(b)
}

pub fn load(path: &Path, hotkey: u16) -> Result<Config, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    parse(&text, hotkey).map_err(|e| format!("{}: {e}", path.display()))
}

#[derive(Debug)]
pub struct Shortcuts {
    hotkey: u16,
    cfg: Config,
    gesture: Gesture,
    held: BTreeSet<u16>,
    /// The running dictation: when it started, and whether the hands-free toggle started it.
    rec: Option<(u64, bool)>,
    warned: bool,
    /// paste-last or copy-last, waiting for every key to be released.
    pending: Option<Cmd>,
}

impl Shortcuts {
    pub fn new(hotkey: u16, cfg: Config) -> Self {
        Shortcuts { hotkey, cfg, gesture: Gesture::default(), held: BTreeSet::new(), rec: None, warned: false, pending: None }
    }

    /// Recording hands-free: after a double tap, or started by the toggle.
    pub fn hands_free(&self) -> bool {
        self.gesture.hands_free() || matches!(self.rec, Some((_, true)))
    }

    /// One evdev key event (value 1 down, 0 up, 2 autorepeat), or None when 50 ms passed
    /// without one. Every call is also a clock tick.
    pub fn feed(&mut self, key: Option<(u16, i32)>, now: u64) -> Vec<Cmd> {
        let mut out = vec![];
        if let Some((code, value)) = key {
            self.key(code, value, now, &mut out);
        }
        self.gesture(Event::Tick(now), now, &mut out);
        if let Some((t0, _)) = self.rec {
            // A cap of a minute or less warns at once.
            if now - t0 >= self.cfg.max_ms {
                self.end(Action::Stop, &mut out);
            } else if now - t0 >= self.cfg.max_ms.saturating_sub(WARN_LEAD_MS) && !self.warned {
                self.warned = true;
                out.push(Cmd::MaxLengthWarning);
            }
        }
        out
    }

    fn key(&mut self, code: u16, value: i32, now: u64, out: &mut Vec<Cmd>) {
        match value {
            0 => {
                self.held.remove(&code);
                if self.held.is_empty() {
                    out.extend(self.pending.take());
                }
                if code == self.hotkey {
                    self.gesture(Event::Up(now), now, out);
                }
                return;
            }
            1 => {
                self.held.insert(code);
            }
            _ => return,
        }
        if code == KEY_ESC && self.rec.is_some() {
            return self.end(Action::Cancel, out);
        }
        if self.cfg.hands_free.matches(&self.held, code) {
            return match self.rec {
                None => {
                    self.started(now, true);
                    out.push(Cmd::Dictation(Action::Start));
                }
                Some((t0, _)) => self.end(if now - t0 < DOUBLE_TAP_MS { Action::Cancel } else { Action::Stop }, out),
            };
        }
        for (c, cmd) in [(&self.cfg.paste_last, Cmd::PasteLast), (&self.cfg.copy_last, Cmd::CopyLast)] {
            if c.matches(&self.held, code) {
                self.pending = Some(cmd);
                return;
            }
        }
        if code == self.hotkey && matches!(self.rec, Some((_, true))) {
            return self.end(Action::Stop, out);
        }
        self.gesture(if code == self.hotkey { Event::Down(now) } else { Event::Other }, now, out);
    }

    fn gesture(&mut self, ev: Event, now: u64, out: &mut Vec<Cmd>) {
        for a in self.gesture.feed(ev) {
            match a {
                Action::Start => self.started(now, false),
                _ => self.rec = None,
            }
            out.push(Cmd::Dictation(a));
        }
    }

    fn started(&mut self, now: u64, toggle: bool) {
        self.rec = Some((now, toggle));
        self.warned = false;
    }

    /// End the dictation from outside the gesture. The gesture starts over, so the release of a
    /// hotkey still held does nothing.
    fn end(&mut self, a: Action, out: &mut Vec<Cmd>) {
        self.reset();
        out.push(Cmd::Dictation(a));
    }

    /// The dictation ended without a key (its mic was unplugged): forget it, so the next press
    /// starts a new one, and neither Esc, the toggle nor the length cap acts on it.
    pub fn reset(&mut self) {
        self.rec = None;
        self.gesture = Gesture::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Action::*;

    const FN: u16 = crate::KEY_FN;
    const LSHIFT: u16 = 42;
    const LALT: u16 = 56;
    const RALT: u16 = 100;
    const LCTRL: u16 = 29;
    const LMETA: u16 = 125;
    const Z: u16 = 44;
    const X: u16 = 45;
    const SPACE: u16 = 57;

    fn defaults() -> Config {
        parse("", FN).unwrap()
    }

    /// Feed (code, value, ms) events, each followed by its own tick, and collect the commands.
    fn run(s: &mut Shortcuts, evs: &[(u16, i32, u64)]) -> Vec<Cmd> {
        evs.iter().flat_map(|&(c, v, t)| s.feed(Some((c, v)), t)).collect()
    }

    fn d(a: Action) -> Cmd {
        Cmd::Dictation(a)
    }

    fn press(keys: &[u16], t: u64) -> Vec<(u16, i32, u64)> {
        let down = keys.iter().map(|&k| (k, 1, t));
        let up = keys.iter().rev().map(|&k| (k, 0, t + 50));
        down.chain(up).collect()
    }

    #[test]
    fn esc_cancels_a_hold_a_double_tap_and_a_toggle() {
        let mut s = Shortcuts::new(FN, defaults());
        // Holding fn, Esc: cancelled, and fn's release afterwards does not stop or start anything.
        assert_eq!(run(&mut s, &[(FN, 1, 0), (KEY_ESC, 1, 2000), (KEY_ESC, 0, 2050), (FN, 0, 3000), (0, 0, 9000)]),
                   [d(Start), d(Cancel)]);
        // Double-tap hands-free, then Esc much later.
        assert_eq!(run(&mut s, &[(FN, 1, 10_000), (FN, 0, 10_100), (FN, 1, 10_300), (FN, 0, 10_400), (KEY_ESC, 1, 60_000), (KEY_ESC, 0, 60_050)]),
                   [d(Start), d(Cancel)]);
        // Started by the toggle.
        let mut evs = press(&[LCTRL, LMETA, SPACE], 100_000);
        evs.push((KEY_ESC, 1, 200_000));
        assert_eq!(run(&mut s, &evs), [d(Start), d(Cancel)]);
    }

    #[test]
    fn esc_with_nothing_recording_does_nothing() {
        let mut s = Shortcuts::new(FN, defaults());
        assert_eq!(run(&mut s, &[(KEY_ESC, 1, 0), (KEY_ESC, 0, 50)]), []);
        // ...and the next dictation still works normally.
        assert_eq!(run(&mut s, &[(FN, 1, 1000), (FN, 0, 2000)]), [d(Start), d(Stop)]);
    }

    #[test]
    fn paste_and_copy_last_fire_once_every_key_is_up() {
        let mut s = Shortcuts::new(FN, defaults());
        // Shift+Alt+Z, released in any order. Nothing while a key is still down: typed with
        // Shift and Alt held, the text would come out as other characters.
        let evs = [(LSHIFT, 1, 0), (LALT, 1, 10), (Z, 1, 20), (Z, 2, 520), (LSHIFT, 0, 600), (Z, 0, 610)];
        assert_eq!(run(&mut s, &evs), []);
        assert_eq!(s.feed(Some((LALT, 0)), 620), [Cmd::PasteLast]);
        assert_eq!(run(&mut s, &press(&[LSHIFT, RALT, X], 1000)), [Cmd::CopyLast], "either Alt");
    }

    #[test]
    fn a_combo_needs_exactly_its_keys() {
        let mut s = Shortcuts::new(FN, defaults());
        assert_eq!(run(&mut s, &press(&[LALT, Z], 0)), [], "Alt+Z is not Shift+Alt+Z");
        assert_eq!(run(&mut s, &press(&[LCTRL, LSHIFT, LALT, Z], 1000)), [], "Ctrl+Shift+Alt+Z is a different shortcut");
        assert_eq!(run(&mut s, &press(&[Z, LSHIFT, LALT], 2000)), [], "Z pressed first, then the modifiers");
    }

    #[test]
    fn hands_free_toggle_starts_stops_and_cancels() {
        let mut s = Shortcuts::new(FN, defaults());
        let toggle = |t| press(&[LCTRL, LMETA, SPACE], t);
        assert_eq!(run(&mut s, &toggle(0)), [d(Start)]);
        // Typing and ticks while hands-free do not end it.
        assert_eq!(run(&mut s, &[(Z, 1, 5000), (Z, 0, 5050), (0, 0, 60_000)]), []);
        assert_eq!(run(&mut s, &toggle(70_000)), [d(Stop)]);
        // A second press within 500 ms of the start cancels (Wispr's debounce); at 500 it stops.
        assert_eq!(run(&mut s, &[toggle(100_000), toggle(100_449)].concat()), [d(Start), d(Cancel)]);
        assert_eq!(run(&mut s, &[toggle(200_000), toggle(200_500)].concat()), [d(Start), d(Stop)]);
    }

    #[test]
    fn hands_free_is_reported_for_the_toggle_and_the_double_tap() {
        // 🤫 turns orange for both ways into hands-free, and not for a hold.
        let mut s = Shortcuts::new(FN, defaults());
        run(&mut s, &press(&[LCTRL, LMETA, SPACE], 0));
        assert!(s.hands_free(), "toggle");
        run(&mut s, &press(&[LCTRL, LMETA, SPACE], 5000));
        assert!(!s.hands_free(), "stopped");
        run(&mut s, &[(FN, 1, 10_000)]);
        assert!(!s.hands_free(), "a hold");
        run(&mut s, &[(FN, 0, 10_100), (FN, 1, 10_300)]);
        assert!(s.hands_free(), "double tap");
        run(&mut s, &[(KEY_ESC, 1, 20_000)]);
        assert!(!s.hands_free(), "cancelled");
    }

    #[test]
    fn after_a_reset_the_next_press_starts_a_new_dictation() {
        let mut s = Shortcuts::new(FN, defaults());
        let toggle = press(&[LCTRL, LMETA, SPACE], 0);
        assert_eq!(run(&mut s, &toggle), [d(Start)]);
        s.reset(); // the mic went away and the daemon typed what was said
        assert!(!s.hands_free());
        assert_eq!(run(&mut s, &[(KEY_ESC, 1, 1000), (KEY_ESC, 0, 1050)]), [], "Esc has nothing to cancel");
        assert_eq!(s.feed(None, MAX_MS + 1000), [], "no cap on a dictation that ended");
        assert_eq!(run(&mut s, &press(&[LCTRL, LMETA, SPACE], 2_000_000)), [d(Start)], "the toggle starts anew");
    }

    #[test]
    fn the_hotkey_stops_a_toggled_dictation_without_starting_another() {
        let mut s = Shortcuts::new(FN, defaults());
        let mut evs = press(&[LCTRL, LMETA, SPACE], 0);
        evs.extend([(FN, 1, 5000), (FN, 0, 5100), (0, 0, 9000)]);
        assert_eq!(run(&mut s, &evs), [d(Start), d(Stop)]);
    }

    #[test]
    fn the_toggle_ends_a_double_tap_dictation() {
        let mut s = Shortcuts::new(FN, defaults());
        let mut evs = vec![(FN, 1, 0), (FN, 0, 100), (FN, 1, 300), (FN, 0, 400)];
        evs.extend(press(&[LCTRL, LMETA, SPACE], 10_000));
        evs.extend([(FN, 1, 20_000)]);
        assert_eq!(run(&mut s, &evs), [d(Start), d(Stop), d(Start)], "fn afterwards starts a fresh one");
    }

    #[test]
    fn hotkey_gestures_still_work_through_the_shortcut_layer() {
        let mut s = Shortcuts::new(FN, defaults());
        assert_eq!(run(&mut s, &[(FN, 1, 0), (FN, 0, 600)]), [d(Start), d(Stop)], "hold");
        assert_eq!(run(&mut s, &[(FN, 1, 1000), (FN, 0, 1100), (0, 0, 1600)]), [d(Start), d(TooShort)], "tap");
        assert_eq!(run(&mut s, &[(FN, 1, 2000), (59, 1, 2100), (FN, 0, 2200)]), [d(Start), d(Cancel)], "fn+F1 chord");
        assert_eq!(run(&mut s, &[(FN, 1, 3000), (FN, 2, 3500), (FN, 2, 3600)]), [d(Start)], "autorepeat is not a press");
    }

    #[test]
    fn warning_at_19_minutes_and_stop_at_20() {
        let mut s = Shortcuts::new(FN, defaults());
        assert_eq!(run(&mut s, &press(&[LCTRL, LMETA, SPACE], 1000)), [d(Start)]);
        assert_eq!(s.feed(None, 1000 + MAX_MS - WARN_LEAD_MS - 1), []);
        assert_eq!(s.feed(None, 1000 + MAX_MS - WARN_LEAD_MS), [Cmd::MaxLengthWarning]);
        assert_eq!(s.feed(None, 1000 + MAX_MS - WARN_LEAD_MS + 50), [], "warned once");
        assert_eq!(s.feed(None, 1000 + MAX_MS - 1), []);
        assert_eq!(s.feed(None, 1000 + MAX_MS), [d(Stop)], "stopped and transcribed, not cancelled");
        assert_eq!(s.feed(None, 1000 + 2 * MAX_MS), []);
        assert_eq!((MAX_MS - WARN_LEAD_MS, MAX_MS), (1_140_000, 1_200_000), "19 and 20 min when config.json sets nothing");
    }

    #[test]
    fn a_20_minute_hold_stops_and_the_late_release_does_nothing() {
        let mut s = Shortcuts::new(FN, defaults());
        assert_eq!(s.feed(Some((FN, 1)), 0), [d(Start)]);
        assert_eq!(s.feed(None, MAX_MS - WARN_LEAD_MS), [Cmd::MaxLengthWarning]);
        assert_eq!(s.feed(None, MAX_MS), [d(Stop)]);
        assert_eq!(run(&mut s, &[(FN, 0, MAX_MS + 5000), (0, 0, MAX_MS + 9000)]), []);
        // The next dictation gets its own warning.
        assert_eq!(s.feed(Some((FN, 1)), 2 * MAX_MS), [d(Start)]);
        assert_eq!(s.feed(None, 2 * MAX_MS + MAX_MS - WARN_LEAD_MS), [Cmd::MaxLengthWarning]);
    }

    #[test]
    fn defaults_are_wisprs_windows_keys() {
        let c = defaults();
        assert_eq!(c.paste_last, Combo(vec![vec![42, 54], vec![56, 100], vec![Z]]));
        assert_eq!(c.copy_last, Combo(vec![vec![42, 54], vec![56, 100], vec![X]]));
        assert_eq!(c.hands_free, Combo(vec![vec![29, 97], vec![125, 126], vec![SPACE]]));
    }

    #[test]
    fn the_cap_is_configurable_for_holds_double_taps_and_the_toggle() {
        // As the Mac's FnGestureTests.testCapIsConfigurable: a 5 min cap warns at 4 and stops at 5.
        let min = 60_000;
        let cfg = parse(r#"{"dictation": {"max_minutes": 5}}"#, FN).unwrap();
        assert_eq!(cfg.max_ms, 5 * min);
        let starts: [&[(u16, i32, u64)]; 3] = [&[(FN, 1, 0)], &[(FN, 1, 0), (FN, 0, 100), (FN, 1, 300), (FN, 0, 400)], &press(&[LCTRL, LMETA, SPACE], 0)];
        for (i, start) in starts.into_iter().enumerate() {
            let mut s = Shortcuts::new(FN, cfg.clone());
            assert_eq!(run(&mut s, start), [d(Start)], "start {i}");
            assert_eq!(s.feed(None, 4 * min - 1), [], "start {i}");
            assert_eq!(s.feed(None, 4 * min), [Cmd::MaxLengthWarning], "start {i}: one minute before the cap");
            assert_eq!(s.feed(None, 5 * min - 1), [], "start {i}: warned once");
            assert_eq!(s.feed(None, 5 * min), [d(Stop)], "start {i}: stopped and transcribed");
            assert_eq!(s.feed(None, 20 * min), [], "start {i}: the default cap does not act too");
        }
        // A longer cap: nothing at 19 or 20 min.
        let mut s = Shortcuts::new(FN, parse(r#"{"dictation": {"max_minutes": 45}}"#, FN).unwrap());
        assert_eq!(s.feed(Some((FN, 1)), 0), [d(Start)]);
        assert_eq!(s.feed(None, 20 * min), []);
        assert_eq!(s.feed(None, 44 * min), [Cmd::MaxLengthWarning]);
        assert_eq!(s.feed(None, 45 * min), [d(Stop)]);
    }

    #[test]
    fn a_one_minute_cap_warns_at_the_start() {
        let mut s = Shortcuts::new(FN, parse(r#"{"dictation": {"max_minutes": 1}}"#, FN).unwrap());
        assert_eq!(s.feed(Some((FN, 1)), 1000), [d(Start), Cmd::MaxLengthWarning]);
        assert_eq!(s.feed(None, 60_999), []);
        assert_eq!(s.feed(None, 61_000), [d(Stop)]);
    }

    #[test]
    fn max_minutes_must_be_whole_minutes_from_1_to_a_day() {
        let e = |t: &str| parse(t, FN).unwrap_err();
        assert_eq!(parse(r#"{"dictation": {}}"#, FN).unwrap().max_ms, MAX_MS);
        assert_eq!(parse(r#"{"dictation": {"max_minutes": 1440}}"#, FN).unwrap().max_ms, 1440 * 60_000);
        for bad in ["0", "-5", "2.5", "\"10\"", "1441", "null"] {
            assert_eq!(e(&format!(r#"{{"dictation": {{"max_minutes": {bad}}}}}"#)),
                       format!("dictation.max_minutes: expected whole minutes from 1 to 1440, got {bad}"));
        }
        assert_eq!(e(r#"{"dictation": {"max_minute": 5}}"#), "unknown dictation setting \"max_minute\" (max_minutes)");
        assert_eq!(e(r#"{"dictation": 5}"#), "\"dictation\" must be an object");
        assert!(load(Path::new("/nonexistent/shepetal/config.json"), FN).is_ok_and(|c| c.max_ms == MAX_MS));
    }

    #[test]
    fn config_overrides_and_other_settings_are_skipped() {
        // One config.json for the daemon: the retention setting sits next to the shortcuts.
        let json = r#"{"retention": "delete_after_24h", "history": {"paste_last": 3},
                       "shortcuts": {"paste_last": "Ctrl+Shift+V", "hands_free": "leftmeta+f9"}}"#;
        let c = parse(json, FN).unwrap();
        assert_eq!(c.paste_last, Combo(vec![vec![29, 97], vec![42, 54], vec![47]]));
        assert_eq!(c.copy_last, defaults().copy_last, "not set: default");
        assert_eq!(c.hands_free, Combo(vec![vec![125], vec![67]]));
    }

    #[test]
    fn key_names_map_to_evdev_codes() {
        // linux/input-event-codes.h
        for (name, code) in [("q", 16), ("p", 25), ("a", 30), ("l", 38), ("z", 44), ("m", 50), ("1", 2), ("9", 10),
                             ("0", 11), ("f1", 59), ("f10", 68), ("f11", 87), ("f12", 88), ("f13", 183), ("f24", 194),
                             ("space", 57), ("183", 183)] {
            assert_eq!(key(name), Some(code), "{name}");
        }
        assert_eq!(key("f25"), None);
        assert_eq!(key("ä"), None);
    }

    #[test]
    fn validation_rejects_what_wispr_rejects() {
        let err = |s: &str| combo(s, FN).unwrap_err();
        assert!(err("ctrl+shift+alt+z").contains("at most 3"), "{}", err("ctrl+shift+alt+z"));
        assert!(combo("ctrl+shift+z", FN).is_ok(), "3 keys is fine");
        assert!(err("z").contains("needs a modifier"));
        assert!(err("space").contains("needs a modifier"));
        assert!(err("ctrl+alt").contains("exactly one key"), "modifier-only would fire inside every Ctrl+Alt chord");
        assert!(err("ctrl+a+b").contains("exactly one key"));
        assert!(err("leftalt+rightalt+z").contains("alt twice"));
        assert!(err("alt+alt+z").contains("alt twice"));
        assert!(err("ctrl+esc").contains("Esc"));
        assert!(err("ctrl+banana").contains("unknown key"));
    }

    #[test]
    fn combos_that_clash_with_the_hotkey_are_rejected() {
        assert!(combo("fn+z", FN).unwrap_err().contains("dictation hotkey"));
        assert!(combo("ctrl+464", FN).unwrap_err().contains("dictation hotkey"));
        assert!(combo("rightalt+z", RALT).unwrap_err().contains("dictation hotkey"));
        assert!(combo("ctrl+capslock", 58).unwrap_err().contains("dictation hotkey"));
        // "alt" with Right Alt as the hotkey means Left Alt only, so pressing the hotkey never
        // completes a shortcut.
        let c = parse("", RALT).unwrap();
        assert_eq!(c.paste_last, Combo(vec![vec![42, 54], vec![LALT], vec![Z]]));
        let mut s = Shortcuts::new(RALT, c);
        assert_eq!(run(&mut s, &press(&[LSHIFT, RALT, Z], 0)), [d(Start), d(Cancel)], "a chord on the hotkey, not paste-last");
        assert_eq!(run(&mut s, &press(&[LSHIFT, LALT, Z], 1000)), [Cmd::PasteLast]);
    }

    #[test]
    fn config_errors_name_the_shortcut_and_place() {
        let e = |t: &str| parse(t, FN).unwrap_err();
        assert_eq!(e(r#"{"shortcuts": {"copy_last": "shift+alt+z"}}"#), "copy_last: \"shift+alt+z\" is already paste_last");
        assert_eq!(e(r#"{"shortcuts": {"hands_free": "Alt + Shift + Z"}}"#), "hands_free: \"Alt + Shift + Z\" is already paste_last", "order and case do not matter");
        assert_eq!(e(r#"{"shortcuts": {"paste_lats": "ctrl+v"}}"#), "unknown shortcut \"paste_lats\" (paste_last, copy_last, hands_free)");
        assert_eq!(e(r#"{"shortcuts": {"paste_last": ["ctrl", "v"]}}"#), "paste_last: expected keys as a string, such as \"shift+alt+z\"");
        assert_eq!(e(r#"{"shortcuts": "ctrl+v"}"#), "\"shortcuts\" must be an object");
        let broken = e("{\"shortcuts\":\n {\"paste_last\" \"ctrl+v\"}}");
        assert_eq!(broken, "expected `:` at line 2 column 16", "broken JSON names the place");
        assert!(e(r#"{"shortcuts": {"paste_last": "z"}}"#).starts_with("paste_last: "));
        assert_eq!(parse(r#"{"retention": "keep"}"#, FN), Ok(defaults()), "no shortcuts: defaults");
    }

    #[test]
    fn config_file_location_and_missing_file() {
        // The same file the retention setting is read from, so the daemon has one settings file.
        assert_eq!(config_file(None, "/home/me"), PathBuf::from("/home/me/.config/shepetal/config.json"));
        assert_eq!(config_file(Some("/cfg"), "/home/me"), PathBuf::from("/cfg/shepetal/config.json"));
        assert_eq!(config_file(Some("rel"), "/home/me"), PathBuf::from("/home/me/.config/shepetal/config.json"));
        let dir = std::env::temp_dir().join(format!("shepetal-shortcuts-{}", std::process::id()));
        assert_eq!(load(&dir.join("none.json"), FN), Ok(defaults()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("bad.json"), r#"{"shortcuts": {"paste_last": "v"}}"#).unwrap();
        let err = load(&dir.join("bad.json"), FN).unwrap_err();
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(err.contains("bad.json: paste_last: \"v\" needs a modifier"), "{err}");
    }
}
