//! Every shepetal key, and the 20 min cap. Pure: feed it evdev key events (code, value) with
//! millisecond timestamps. It owns the dictation key's `Gesture` too, so a recording started by
//! either path has one owner.
//!
//! - The dictation key: fn, one key from `SHEPETAL_KEY`, or a combo of up to 3 keys or mouse
//!   buttons from config.json (hold to talk, double-tap for hands-free).
//! - Esc cancels a running dictation. Its audio is kept as `*.cancelled.wav` (goal rule 4).
//!   With nothing recording Esc does nothing. shepetal reads evdev without a grab, so no key,
//!   Esc included, is ever swallowed: the focused app always gets it.
//! - paste-last and copy-last (Wispr's Windows defaults Shift+Alt+Z and Shift+Alt+X) fire once
//!   every key is up, so the held Shift and Alt do not change the typed text.
//! - A dedicated hands-free toggle (Wispr's Windows default Ctrl+Win+Space): one press starts,
//!   the next stops, a second press within 500 ms of the start cancels. The hotkey stops it too.
//! - A warning at 19 min and a stop (transcribed as usual) at 20 min, as Wispr
//!   (docs/re/dictation-input.md, section 2.3).
//!
//! The combos live in `~/.config/shepetal/config.json`, the one settings file of the daemon:
//!
//! ```json
//! {"shortcuts": {"dictation": "fn", "paste_last": "shift+alt+z", "copy_last": "shift+alt+x", "hands_free": "ctrl+meta+space"}}
//! ```

use crate::gesture::{Action, Event, Gesture, DOUBLE_TAP_MS};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

pub const KEY_ESC: u16 = 1;
pub const WARN_MS: u64 = 19 * 60_000;
pub const MAX_MS: u64 = 20 * 60_000;
/// Shown next to 🤫 at 19 min. Our own wording.
pub const WARNING: &str = "Recording stops in 1 minute";

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Cmd {
    Dictation(Action),
    MaxLengthWarning,
    PasteLast,
    CopyLast,
}

/// A key combo: per key, the evdev codes that count as it ("alt" is Left Alt or Right Alt).
/// The modifiers and mouse buttons come first, the one other key (if any) last.
#[derive(Debug, Clone, PartialEq)]
pub struct Combo(Vec<Vec<u16>>);

const MODIFIERS: [u16; 8] = [29, 97, 42, 54, 56, 100, 125, 126];
const BTN_LEFT: u16 = 0x110;
const BTN_RIGHT: u16 = 0x111;

/// A mouse button (BTN_LEFT ... BTN_TASK in linux/input-event-codes.h).
pub fn is_button(code: u16) -> bool {
    (0x110..=0x117).contains(&code)
}

/// A key that types something: letters, digits, punctuation, space, tab, enter, backspace.
fn typing(code: u16) -> bool {
    matches!(code, 2..=28 | 30..=41 | 43..=53 | 57)
}

fn plain(codes: &[u16]) -> bool {
    codes.iter().all(|c| !MODIFIERS.contains(c) && !is_button(*c))
}

impl Combo {
    /// Exactly these keys are held and `pressed` is one of them; with a non-modifier key in the
    /// combo, `pressed` is that key, as in any chord.
    fn matches(&self, held: &BTreeSet<u16>, pressed: u16) -> bool {
        let last = self.0.last().filter(|k| plain(k)).map_or(&self.0[..], std::slice::from_ref);
        held.len() == self.0.len()
            && last.iter().any(|k| k.contains(&pressed))
            && self.0.iter().all(|k| k.iter().any(|c| held.contains(c)))
    }

    fn has(&self, code: u16) -> bool {
        self.0.iter().any(|k| k.contains(&code))
    }

    /// Every key of `self` is a key of `other` too (sides ignored): `other` holds `self`.
    fn within(&self, other: &Combo) -> bool {
        self.0.iter().all(|k| other.0.iter().any(|o| k.iter().any(|c| o.contains(c))))
    }

    /// Every evdev code the combo listens to.
    pub fn codes(&self) -> impl Iterator<Item = u16> + '_ {
        self.0.iter().flatten().copied()
    }

    /// The codes of each key, for checking that some input device can send it.
    pub fn keys(&self) -> &[Vec<u16>] {
        &self.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    /// Hold to talk, double-tap for hands-free: `SHEPETAL_KEY`, else `dictation`, else fn.
    pub dictation: Combo,
    /// How the hint names it: "fn", "ctrl+alt", "mouse4", "key 58".
    pub dictation_name: String,
    pub paste_last: Combo,
    pub copy_last: Combo,
    pub hands_free: Combo,
}

pub const DEFAULTS: [(&str, &str); 4] = [
    ("dictation", "fn"),
    ("paste_last", "shift+alt+z"),
    ("copy_last", "shift+alt+x"),
    ("hands_free", "ctrl+meta+space"),
];

/// Desktop and app shortcuts no shepetal key may take (sides ignored): bound here, the desktop
/// or the focused app would act on them too, since nothing is swallowed.
const BLOCKED: &[&str] = &[
    "ctrl+c", "ctrl+v", "ctrl+x", "ctrl+z", "ctrl+y", "ctrl+a", "ctrl+s", "ctrl+q", "ctrl+w", "ctrl+t", "ctrl+n",
    "ctrl+f", "ctrl+space", "ctrl+left", "ctrl+right", "ctrl+backspace", "ctrl+delete", "ctrl+insert",
    "ctrl+shift+c", "ctrl+shift+v", "ctrl+shift+t", "ctrl+shift+z", "shift+insert", "shift+delete",
    "alt+tab", "alt+shift+tab", "alt+f1", "alt+f2", "alt+f4", "alt+space",
    "meta+tab", "meta+space", "meta+a", "meta+d", "meta+e", "meta+l", "meta+up", "meta+down", "meta+left", "meta+right",
    "ctrl+alt+t", "ctrl+alt+l", "ctrl+alt+delete", "ctrl+alt+backspace",
    "ctrl+alt+up", "ctrl+alt+down", "ctrl+alt+left", "ctrl+alt+right",
    "ctrl+alt+f1", "ctrl+alt+f2", "ctrl+alt+f3", "ctrl+alt+f4", "ctrl+alt+f5", "ctrl+alt+f6",
    "ctrl+alt+f7", "ctrl+alt+f8", "ctrl+alt+f9", "ctrl+alt+f10", "ctrl+alt+f11", "ctrl+alt+f12",
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

/// Mouse buttons: BTN_MIDDLE, the back button (BTN_SIDE, or BTN_BACK on some mice) and the
/// forward one (BTN_EXTRA or BTN_FORWARD). Numbered as on the Mac: 3 middle, 4 back, 5 forward.
fn mouse(name: &str) -> Option<&'static [u16]> {
    Some(match name {
        "mouse3" | "middle" => &[0x112],
        "mouse4" | "back" | "side" => &[0x113, 0x116],
        "mouse5" | "forward" | "extra" => &[0x114, 0x115],
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

/// The keys of a combo, unchecked: (codes, family for modifiers).
fn keys_of(s: &str) -> Result<Vec<(Vec<u16>, Option<&'static str>)>, String> {
    s.split('+').map(|k| k.trim().to_ascii_lowercase()).map(|n| {
        if let Some((codes, family)) = modifier(&n) {
            return Ok((codes.to_vec(), Some(family)));
        }
        if let Some(codes) = mouse(&n) {
            return Ok((codes.to_vec(), None));
        }
        match key(&n) {
            Some(BTN_LEFT | BTN_RIGHT) | None if matches!(n.as_str(), "mouse1" | "mouse2" | "272" | "273") => {
                Err(format!("{s:?}: left and right click cannot be shortcuts"))
            }
            Some(c) => Ok((vec![c], None)),
            None => Err(format!("{s:?}: unknown key {n:?}")),
        }
    }).collect()
}

/// Parse and validate one combo, with the Mac's rules (ShortcutsTests): at most 3 keys, at most
/// one key besides the modifiers and mouse buttons, each modifier once (no Left Alt + Right Alt),
/// no Esc, nothing that types a character (a bare letter or digit, Shift+A, AltGr+L) and no
/// desktop or app shortcut ([`BLOCKED`]). A mouse button counts as a modifier.
///
/// `dictation` is None for the dictation key itself. It may also be one key that types nothing
/// (fn, capslock, f13, a right-hand Ctrl, Alt or Meta, a mouse button) or modifiers alone
/// (ctrl+alt), since it acts on hold, not on a press. The other shortcuts need a modifier or a
/// mouse button, and a key unless a mouse button is in it, and never hold the dictation keys: a
/// generic modifier ("alt") skips the side that is a one-key dictation key, so the default
/// Shift+Alt+Z still works with SHEPETAL_KEY=rightalt, through Left Alt.
pub fn combo(s: &str, dictation: Option<&Combo>) -> Result<Combo, String> {
    let names = keys_of(s)?;
    if names.len() > 3 {
        return Err(format!("{s:?} has {} keys, at most 3 are allowed", names.len()));
    }
    let (mut keys, mut families, mut others) = (vec![], vec![], vec![]);
    let mut buttons = 0;
    for (n, (codes, family)) in s.split('+').map(|k| k.trim().to_ascii_lowercase()).zip(names) {
        if let Some(family) = family {
            if families.contains(&family) {
                return Err(format!("{s:?} uses {family} twice"));
            }
            families.push(family);
        }
        if codes.contains(&KEY_ESC) {
            return Err(format!("{s:?} uses Esc, which cancels a dictation"));
        }
        let codes: Vec<u16> = match dictation {
            Some(Combo(d)) if d.len() == 1 => codes.into_iter().filter(|c| !d[0].contains(c)).collect(),
            _ => codes,
        };
        if codes.is_empty() {
            return Err(format!("{s:?} uses {n}, the dictation hotkey"));
        }
        if family.is_some() || is_button(codes[0]) {
            buttons += is_button(codes[0]) as usize;
            keys.push(codes);
        } else {
            others.push(codes);
        }
    }
    if others.len() > 1 {
        return Err(format!("{s:?} needs exactly one key besides the modifiers"));
    }
    let other = others.first().map(|k| k[0]);
    if dictation.is_none() {
        let lone_ok = match (&keys[..], other) {
            ([], Some(k)) => !typing(k),
            ([m], None) => buttons == 1 || matches!(m[..], [97] | [100] | [126]),
            _ => true,
        };
        if !lone_ok {
            return Err(match other {
                Some(_) => format!("{s:?} needs a modifier: ctrl, alt, shift, meta or a mouse button"),
                None => format!("{s:?} is a key you press all the time: use rightctrl, rightalt or rightmeta alone, or a combo"),
            });
        }
    } else if families.is_empty() && buttons == 0 {
        return Err(format!("{s:?} needs a modifier: ctrl, alt, shift, meta or a mouse button"));
    } else if other.is_none() && buttons == 0 {
        return Err(format!("{s:?} needs exactly one key besides the modifiers"));
    }
    // Shift or AltGr (Right Alt) with a typing key types a character: every capital Z, or @ on
    // a German layout.
    if other.is_some_and(typing) && buttons == 0 && !keys.is_empty()
        && keys.iter().all(|k| k[..] == [42, 54] || k.iter().all(|c| [42, 54, 100].contains(c))) {
        return Err(format!("{s:?} types a character"));
    }
    keys.append(&mut others);
    let c = Combo(keys);
    if let Some(b) = BLOCKED.iter().find(|b| keys_of(b).is_ok_and(|k| same_keys(&c, &Combo(k.into_iter().map(|x| x.0).collect())))) {
        return Err(format!("{s:?} is {b}, a shortcut the desktop or apps already use"));
    }
    if let Some(d) = dictation.filter(|d| d.0.len() > 1) {
        if d.within(&c) || c.within(d) {
            return Err(format!("{s:?} overlaps the dictation keys, so one would set off the other"));
        }
    }
    Ok(c)
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

/// The dictation key `SHEPETAL_KEY` names (any one key, by name or evdev code, unchecked as
/// before combos existed), and how the hint names it.
fn env_key(k: &str) -> Result<(Combo, String), String> {
    let code = crate::parse_key(k).ok_or(format!("unknown SHEPETAL_KEY {k:?}"))?;
    // A raw evdev code reads "Hold key 58 to talk" in the hint, not "Hold 58 to talk".
    let name = if k.parse::<u16>().is_ok() { format!("key {k}") } else { k.to_string() };
    Ok((Combo(vec![vec![code]]), name))
}

/// Read the `shortcuts` object of config.json (an empty or missing file means the defaults).
/// Other keys belong to other features and are skipped; an unknown name in `shortcuts` is an
/// error, so a typo is not silently ignored. `shepetal_key`, the SHEPETAL_KEY variable, wins
/// over `dictation`.
pub fn parse(json: &str, shepetal_key: Option<&str>) -> Result<Config, String> {
    let mut vals = DEFAULTS.map(|(k, v)| (k, v.to_string()));
    let v: serde_json::Value = if json.trim().is_empty() { Default::default() } else { serde_json::from_str(json).map_err(|e| e.to_string())? };
    if let Some(set) = v.get("shortcuts") {
        for (k, val) in set.as_object().ok_or("\"shortcuts\" must be an object")? {
            let slot = vals.iter_mut().find(|(name, _)| name == k)
                .ok_or(format!("unknown shortcut {k:?} (dictation, paste_last, copy_last, hands_free)"))?;
            slot.1 = val.as_str().ok_or(format!("{k}: expected keys as a string, such as \"shift+alt+z\""))?.to_string();
        }
    }
    let (dictation, dictation_name) = match shepetal_key {
        Some(k) => env_key(k)?,
        None => (combo(&vals[0].1, None).map_err(|e| format!("dictation: {e}"))?, vals[0].1.to_ascii_lowercase().replace(' ', "")),
    };
    let mut combos: Vec<(&str, Combo)> = vec![("dictation", dictation.clone())];
    for (name, v) in &vals[1..] {
        let c = combo(v, Some(&dictation)).map_err(|e| format!("{name}: {e}"))?;
        if let Some((other, _)) = combos.iter().find(|(_, o)| same_keys(o, &c)) {
            return Err(format!("{name}: {v:?} is already {other}"));
        }
        combos.push((*name, c));
    }
    let mut it = combos.into_iter().skip(1).map(|(_, c)| c);
    let mut next = || it.next().unwrap();
    Ok(Config { dictation, dictation_name, paste_last: next(), copy_last: next(), hands_free: next() })
}

/// The same keys, sides ignored: Left Alt and Right Alt are both alt.
fn same_keys(a: &Combo, b: &Combo) -> bool {
    a.0.len() == b.0.len() && a.within(b) && b.within(a)
}

pub fn load(path: &Path, shepetal_key: Option<&str>) -> Result<Config, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    parse(&text, shepetal_key).map_err(|e| format!("{}: {e}", path.display()))
}

#[derive(Debug)]
pub struct Shortcuts {
    cfg: Config,
    gesture: Gesture,
    held: BTreeSet<u16>,
    /// The dictation keys are down: the next release of one of them is the gesture's release.
    down: bool,
    /// The running dictation: when it started, and whether the hands-free toggle started it.
    rec: Option<(u64, bool)>,
    warned: bool,
    /// paste-last or copy-last, waiting for every key to be released.
    pending: Option<Cmd>,
}

impl Shortcuts {
    pub fn new(cfg: Config) -> Self {
        Shortcuts { cfg, gesture: Gesture::default(), held: BTreeSet::new(), down: false, rec: None, warned: false, pending: None }
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
            if now - t0 >= MAX_MS {
                self.end(Action::Stop, &mut out);
            } else if now - t0 >= WARN_MS && !self.warned {
                self.warned = true;
                out.push(Cmd::MaxLengthWarning);
            }
        }
        out
    }

    fn used(&self, code: u16) -> bool {
        let c = &self.cfg;
        [&c.dictation, &c.paste_last, &c.copy_last, &c.hands_free].iter().any(|k| k.has(code))
    }

    /// The dictation keys are all down: a one-key one on its press, whatever else is held (as
    /// before combos); a combo once exactly its keys are held, in any order.
    fn dictation_complete(&self) -> bool {
        let d = &self.cfg.dictation.0;
        d.len() == 1 || (self.held.len() == d.len() && d.iter().all(|k| k.iter().any(|c| self.held.contains(c))))
    }

    fn key(&mut self, code: u16, value: i32, now: u64, out: &mut Vec<Cmd>) {
        // A click with a button no shortcut uses is not a key: clicking while holding the
        // dictation key must not cancel it as a chord would.
        if is_button(code) && !self.used(code) {
            return;
        }
        match value {
            0 => {
                self.held.remove(&code);
                if self.held.is_empty() {
                    out.extend(self.pending.take());
                }
                if self.down && self.cfg.dictation.has(code) {
                    self.down = false;
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
        if !self.cfg.dictation.has(code) {
            return self.gesture(Event::Other, now, out);
        }
        // A key of a dictation combo that does not complete it yet is no other key either.
        if !self.dictation_complete() {
            return;
        }
        if matches!(self.rec, Some((_, true))) {
            return self.end(Action::Stop, out);
        }
        self.down = true;
        self.gesture(Event::Down(now), now, out);
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
    /// starts a new one, and neither Esc, the toggle nor the 20 min cap acts on it.
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
        parse("", None).unwrap()
    }

    fn one(k: u16) -> Combo {
        Combo(vec![vec![k]])
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
        let mut s = Shortcuts::new(defaults());
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
        let mut s = Shortcuts::new(defaults());
        assert_eq!(run(&mut s, &[(KEY_ESC, 1, 0), (KEY_ESC, 0, 50)]), []);
        // ...and the next dictation still works normally.
        assert_eq!(run(&mut s, &[(FN, 1, 1000), (FN, 0, 2000)]), [d(Start), d(Stop)]);
    }

    #[test]
    fn paste_and_copy_last_fire_once_every_key_is_up() {
        let mut s = Shortcuts::new(defaults());
        // Shift+Alt+Z, released in any order. Nothing while a key is still down: typed with
        // Shift and Alt held, the text would come out as other characters.
        let evs = [(LSHIFT, 1, 0), (LALT, 1, 10), (Z, 1, 20), (Z, 2, 520), (LSHIFT, 0, 600), (Z, 0, 610)];
        assert_eq!(run(&mut s, &evs), []);
        assert_eq!(s.feed(Some((LALT, 0)), 620), [Cmd::PasteLast]);
        assert_eq!(run(&mut s, &press(&[LSHIFT, RALT, X], 1000)), [Cmd::CopyLast], "either Alt");
    }

    #[test]
    fn a_combo_needs_exactly_its_keys() {
        let mut s = Shortcuts::new(defaults());
        assert_eq!(run(&mut s, &press(&[LALT, Z], 0)), [], "Alt+Z is not Shift+Alt+Z");
        assert_eq!(run(&mut s, &press(&[LCTRL, LSHIFT, LALT, Z], 1000)), [], "Ctrl+Shift+Alt+Z is a different shortcut");
        assert_eq!(run(&mut s, &press(&[Z, LSHIFT, LALT], 2000)), [], "Z pressed first, then the modifiers");
    }

    #[test]
    fn hands_free_toggle_starts_stops_and_cancels() {
        let mut s = Shortcuts::new(defaults());
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
        let mut s = Shortcuts::new(defaults());
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
        let mut s = Shortcuts::new(defaults());
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
        let mut s = Shortcuts::new(defaults());
        let mut evs = press(&[LCTRL, LMETA, SPACE], 0);
        evs.extend([(FN, 1, 5000), (FN, 0, 5100), (0, 0, 9000)]);
        assert_eq!(run(&mut s, &evs), [d(Start), d(Stop)]);
    }

    #[test]
    fn the_toggle_ends_a_double_tap_dictation() {
        let mut s = Shortcuts::new(defaults());
        let mut evs = vec![(FN, 1, 0), (FN, 0, 100), (FN, 1, 300), (FN, 0, 400)];
        evs.extend(press(&[LCTRL, LMETA, SPACE], 10_000));
        evs.extend([(FN, 1, 20_000)]);
        assert_eq!(run(&mut s, &evs), [d(Start), d(Stop), d(Start)], "fn afterwards starts a fresh one");
    }

    #[test]
    fn hotkey_gestures_still_work_through_the_shortcut_layer() {
        let mut s = Shortcuts::new(defaults());
        assert_eq!(run(&mut s, &[(FN, 1, 0), (FN, 0, 600)]), [d(Start), d(Stop)], "hold");
        assert_eq!(run(&mut s, &[(FN, 1, 1000), (FN, 0, 1100), (0, 0, 1600)]), [d(Start), d(TooShort)], "tap");
        assert_eq!(run(&mut s, &[(FN, 1, 2000), (59, 1, 2100), (FN, 0, 2200)]), [d(Start), d(Cancel)], "fn+F1 chord");
        assert_eq!(run(&mut s, &[(FN, 1, 3000), (FN, 2, 3500), (FN, 2, 3600)]), [d(Start)], "autorepeat is not a press");
    }

    #[test]
    fn warning_at_19_minutes_and_stop_at_20() {
        let mut s = Shortcuts::new(defaults());
        assert_eq!(run(&mut s, &press(&[LCTRL, LMETA, SPACE], 1000)), [d(Start)]);
        assert_eq!(s.feed(None, 1000 + WARN_MS - 1), []);
        assert_eq!(s.feed(None, 1000 + WARN_MS), [Cmd::MaxLengthWarning]);
        assert_eq!(s.feed(None, 1000 + WARN_MS + 50), [], "warned once");
        assert_eq!(s.feed(None, 1000 + MAX_MS - 1), []);
        assert_eq!(s.feed(None, 1000 + MAX_MS), [d(Stop)], "stopped and transcribed, not cancelled");
        assert_eq!(s.feed(None, 1000 + 2 * MAX_MS), []);
        assert_eq!((WARN_MS, MAX_MS), (1_140_000, 1_200_000));
    }

    #[test]
    fn a_20_minute_hold_stops_and_the_late_release_does_nothing() {
        let mut s = Shortcuts::new(defaults());
        assert_eq!(s.feed(Some((FN, 1)), 0), [d(Start)]);
        assert_eq!(s.feed(None, WARN_MS), [Cmd::MaxLengthWarning]);
        assert_eq!(s.feed(None, MAX_MS), [d(Stop)]);
        assert_eq!(run(&mut s, &[(FN, 0, MAX_MS + 5000), (0, 0, MAX_MS + 9000)]), []);
        // The next dictation gets its own warning.
        assert_eq!(s.feed(Some((FN, 1)), 2 * MAX_MS), [d(Start)]);
        assert_eq!(s.feed(None, 2 * MAX_MS + WARN_MS), [Cmd::MaxLengthWarning]);
    }

    #[test]
    fn defaults_are_wisprs_windows_keys() {
        let c = defaults();
        assert_eq!(c.paste_last, Combo(vec![vec![42, 54], vec![56, 100], vec![Z]]));
        assert_eq!(c.copy_last, Combo(vec![vec![42, 54], vec![56, 100], vec![X]]));
        assert_eq!(c.hands_free, Combo(vec![vec![29, 97], vec![125, 126], vec![SPACE]]));
    }

    #[test]
    fn config_overrides_and_other_settings_are_skipped() {
        // One config.json for the daemon: the retention setting sits next to the shortcuts.
        let json = r#"{"retention": "delete_after_24h", "history": {"paste_last": 3},
                       "shortcuts": {"paste_last": "Ctrl+Shift+B", "hands_free": "leftmeta+f9"}}"#;
        let c = parse(json, None).unwrap();
        assert_eq!(c.paste_last, Combo(vec![vec![29, 97], vec![42, 54], vec![48]]));
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
        let err = |s: &str| combo(s, Some(&one(FN))).unwrap_err();
        assert!(err("ctrl+shift+alt+z").contains("at most 3"), "{}", err("ctrl+shift+alt+z"));
        assert!(combo("ctrl+shift+k", Some(&one(FN))).is_ok(), "3 keys is fine");
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
        assert!(combo("fn+z", Some(&one(FN))).unwrap_err().contains("dictation hotkey"));
        assert!(combo("ctrl+464", Some(&one(FN))).unwrap_err().contains("dictation hotkey"));
        assert!(combo("rightalt+z", Some(&one(RALT))).unwrap_err().contains("dictation hotkey"));
        assert!(combo("ctrl+capslock", Some(&one(58))).unwrap_err().contains("dictation hotkey"));
        // "alt" with Right Alt as the hotkey means Left Alt only, so pressing the hotkey never
        // completes a shortcut.
        let c = parse("", Some("rightalt")).unwrap();
        assert_eq!(c.paste_last, Combo(vec![vec![42, 54], vec![LALT], vec![Z]]));
        let mut s = Shortcuts::new(c);
        assert_eq!(run(&mut s, &press(&[LSHIFT, RALT, Z], 0)), [d(Start), d(Cancel)], "a chord on the hotkey, not paste-last");
        assert_eq!(run(&mut s, &press(&[LSHIFT, LALT, Z], 1000)), [Cmd::PasteLast]);
    }

    #[test]
    fn config_errors_name_the_shortcut_and_place() {
        let e = |t: &str| parse(t, None).unwrap_err();
        assert_eq!(e(r#"{"shortcuts": {"copy_last": "shift+alt+z"}}"#), "copy_last: \"shift+alt+z\" is already paste_last");
        assert_eq!(e(r#"{"shortcuts": {"hands_free": "Alt + Shift + Z"}}"#), "hands_free: \"Alt + Shift + Z\" is already paste_last", "order and case do not matter");
        assert_eq!(e(r#"{"shortcuts": {"paste_lats": "ctrl+v"}}"#), "unknown shortcut \"paste_lats\" (dictation, paste_last, copy_last, hands_free)");
        assert_eq!(e(r#"{"shortcuts": {"paste_last": ["ctrl", "v"]}}"#), "paste_last: expected keys as a string, such as \"shift+alt+z\"");
        assert_eq!(e(r#"{"shortcuts": "ctrl+v"}"#), "\"shortcuts\" must be an object");
        let broken = e("{\"shortcuts\":\n {\"paste_last\" \"ctrl+v\"}}");
        assert_eq!(broken, "expected `:` at line 2 column 16", "broken JSON names the place");
        assert!(e(r#"{"shortcuts": {"paste_last": "z"}}"#).starts_with("paste_last: "));
        assert_eq!(parse(r#"{"retention": "keep"}"#, None), Ok(defaults()), "no shortcuts: defaults");
    }

    const BTN_LEFT_: u16 = 0x110;
    const BTN_SIDE: u16 = 0x113;
    const BTN_EXTRA: u16 = 0x114;
    const BTN_BACK: u16 = 0x116;

    fn with(json: &str) -> Config {
        parse(json, None).unwrap()
    }

    #[test]
    fn a_combo_is_a_dictation_key_held_in_any_order() {
        let c = with(r#"{"shortcuts": {"dictation": "Ctrl + Alt"}}"#);
        assert_eq!(c.dictation_name, "ctrl+alt", "the hint says Hold ctrl+alt to talk");
        let mut s = Shortcuts::new(c);
        assert_eq!(run(&mut s, &[(LCTRL, 1, 0), (0, 0, 2000), (LCTRL, 0, 2100)]), [], "one key of the combo is not a press");
        assert_eq!(run(&mut s, &[(LCTRL, 1, 3000), (LALT, 1, 3050), (LALT, 0, 3700), (LCTRL, 0, 3750)]), [d(Start), d(Stop)], "hold");
        assert_eq!(run(&mut s, &[(RALT, 1, 5000), (97, 1, 5010), (97, 0, 5800), (RALT, 0, 5810)]), [d(Start), d(Stop)], "other sides, other order");
        // Double-tap: let one key go and press it again within 0.5 s.
        assert_eq!(run(&mut s, &[(LCTRL, 1, 10_000), (LALT, 1, 10_000), (LALT, 0, 10_100), (LALT, 1, 10_400), (LALT, 0, 10_500), (LCTRL, 0, 10_500)]), [d(Start)]);
        assert!(s.hands_free());
        assert_eq!(run(&mut s, &[(LCTRL, 1, 20_000), (LALT, 1, 20_010)]), [d(Stop)], "the combo again stops hands-free");
        assert_eq!(run(&mut s, &[(LALT, 0, 20_100), (LCTRL, 0, 20_110)]), []);
        // Ctrl+Alt+T is the user's chord, not a dictation: cancelled, as fn+F1.
        assert_eq!(run(&mut s, &[(LCTRL, 1, 30_000), (LALT, 1, 30_000), (20, 1, 30_100)]), [d(Start), d(Cancel)]);
        assert_eq!(run(&mut s, &[(20, 0, 30_200), (LALT, 0, 30_200), (LCTRL, 0, 30_200)]), []);
        // An extra key held first: Shift+Ctrl+Alt is another chord.
        assert_eq!(run(&mut s, &[(LSHIFT, 1, 40_000), (LCTRL, 1, 40_000), (LALT, 1, 40_000), (0, 0, 41_000)]), []);
    }

    #[test]
    fn a_mouse_button_is_a_dictation_key_and_clicks_do_not_cancel_it() {
        let c = with(r#"{"shortcuts": {"dictation": "mouse4", "hands_free": "mouse5", "paste_last": "ctrl+middle"}}"#);
        assert_eq!(c.dictation, Combo(vec![vec![BTN_SIDE, BTN_BACK]]));
        let mut s = Shortcuts::new(c);
        assert_eq!(run(&mut s, &[(BTN_SIDE, 1, 0), (BTN_LEFT_, 1, 200), (BTN_LEFT_, 0, 250), (BTN_SIDE, 0, 900)]), [d(Start), d(Stop)],
                   "a left click while holding the back button is no chord");
        assert_eq!(run(&mut s, &[(BTN_BACK, 1, 2000), (BTN_BACK, 0, 2600)]), [d(Start), d(Stop)], "BTN_BACK mice too");
        assert_eq!(run(&mut s, &[(BTN_SIDE, 1, 3000), (BTN_SIDE, 0, 3100), (BTN_SIDE, 1, 3300), (BTN_SIDE, 0, 3400)]), [d(Start)]);
        assert!(s.hands_free(), "double-click of the button is hands-free");
        assert_eq!(run(&mut s, &[(BTN_SIDE, 1, 9000), (BTN_SIDE, 0, 9100)]), [d(Stop)]);
        assert_eq!(run(&mut s, &press(&[BTN_EXTRA], 20_000)), [d(Start)], "mouse5 alone toggles hands-free");
        assert_eq!(run(&mut s, &press(&[BTN_EXTRA], 30_000)), [d(Stop)]);
        assert_eq!(run(&mut s, &press(&[LCTRL, 0x112], 40_000)), [Cmd::PasteLast], "ctrl+middle");
    }

    #[test]
    fn dictation_validation_matches_the_mac() {
        let dict = |s: &str| parse(&format!(r#"{{"shortcuts": {{"dictation": "{s}"}}}}"#), None);
        for ok in ["fn", "ctrl+alt", "mouse4", "ctrl+mouse5", "rightalt", "rightctrl", "rightmeta", "capslock", "f13",
                   "ctrl+shift+alt", "middle", "meta+f9"] {
            assert!(dict(ok).is_ok(), "{ok}: {:?}", dict(ok));
        }
        let err = |s: &str| dict(s).unwrap_err();
        assert!(err("ctrl+shift+alt+meta").contains("at most 3"), "4 keys");
        assert!(err("ctrl+alt+mouse4+z").contains("at most 3"));
        assert!(err("a").contains("needs a modifier"), "a bare letter");
        assert!(err("7").contains("needs a modifier"), "a bare digit");
        assert!(err("space").contains("needs a modifier"));
        assert!(err("shift+a").contains("types a character"), "every capital A");
        assert!(err("rightalt+l").contains("types a character"), "AltGr+L types @ on a German layout");
        for lone in ["shift", "ctrl", "alt", "leftalt", "leftctrl", "meta", "rightshift"] {
            assert!(err(lone).contains("press all the time"), "{lone}");
        }
        assert!(err("leftalt+rightalt").contains("alt twice"));
        assert!(err("esc").contains("Esc"));
        assert!(err("mouse1").contains("left and right click"));
        assert!(err("ctrl+273").contains("left and right click"));
        assert!(err("ctrl+mouse9").contains("unknown key"));
        for blocked in ["ctrl+c", "ctrl+v", "alt+tab", "alt+f4", "meta+space", "ctrl+space", "ctrl+alt+t", "ctrl+alt+f2",
                        "rightctrl+c", "ctrl+shift+v", "meta+l"] {
            assert!(err(blocked).contains("desktop or apps already use"), "{blocked}: {}", err(blocked));
        }
        // The other shortcuts get the same rules.
        let e = parse(r#"{"shortcuts": {"paste_last": "alt+tab"}}"#, None).unwrap_err();
        assert_eq!(e, "paste_last: \"alt+tab\" is alt+tab, a shortcut the desktop or apps already use");
        assert!(parse(r#"{"shortcuts": {"copy_last": "shift+c"}}"#, None).unwrap_err().contains("types a character"));
        assert!(parse(r#"{"shortcuts": {"copy_last": "ctrl+shift+alt+c"}}"#, None).unwrap_err().contains("at most 3"));
    }

    #[test]
    fn other_shortcuts_may_not_overlap_a_combo_dictation_key() {
        let e = |j: &str| parse(j, None).unwrap_err();
        assert_eq!(e(r#"{"shortcuts": {"dictation": "ctrl+alt", "paste_last": "ctrl+alt+z"}}"#),
                   "paste_last: \"ctrl+alt+z\" overlaps the dictation keys, so one would set off the other");
        assert!(e(r#"{"shortcuts": {"dictation": "ctrl+meta+space"}}"#).starts_with("hands_free: "), "the default hands-free key");
        assert!(e(r#"{"shortcuts": {"dictation": "mouse4", "paste_last": "ctrl+mouse4"}}"#).contains("the dictation hotkey"));
        assert!(e(r#"{"shortcuts": {"dictation": "shift+alt+z"}}"#).starts_with("paste_last: "));
        // Keys of the combo in other shortcuts are fine when they do not hold all of it.
        assert!(parse(r#"{"shortcuts": {"dictation": "ctrl+alt"}}"#, None).is_ok(), "shift+alt+z holds alt but not ctrl");
    }

    #[test]
    fn shepetal_key_still_picks_one_key_and_wins_over_the_config() {
        let json = r#"{"shortcuts": {"dictation": "ctrl+alt"}}"#;
        let c = parse(json, Some("rightalt")).unwrap();
        assert_eq!((c.dictation.clone(), c.dictation_name.as_str()), (one(RALT), "rightalt"));
        assert_eq!(c.paste_last, Combo(vec![vec![42, 54], vec![LALT], vec![Z]]), "generic alt skips the hotkey's side");
        let c = parse("", Some("58")).unwrap();
        assert_eq!((c.dictation, c.dictation_name.as_str()), (one(58), "key 58"));
        assert_eq!(parse("", Some("nope")).unwrap_err(), "unknown SHEPETAL_KEY \"nope\"", "a typo never falls back to fn");
        assert_eq!(parse("", None).unwrap().dictation, one(FN), "nothing set: fn (goal rule 1)");
        assert_eq!(parse("", None).unwrap().dictation_name, "fn");
    }

    #[test]
    fn config_file_location_and_missing_file() {
        // The same file the retention setting is read from, so the daemon has one settings file.
        assert_eq!(config_file(None, "/home/me"), PathBuf::from("/home/me/.config/shepetal/config.json"));
        assert_eq!(config_file(Some("/cfg"), "/home/me"), PathBuf::from("/cfg/shepetal/config.json"));
        assert_eq!(config_file(Some("rel"), "/home/me"), PathBuf::from("/home/me/.config/shepetal/config.json"));
        let dir = std::env::temp_dir().join(format!("shepetal-shortcuts-{}", std::process::id()));
        assert_eq!(load(&dir.join("none.json"), None), Ok(defaults()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("bad.json"), r#"{"shortcuts": {"paste_last": "v"}}"#).unwrap();
        let err = load(&dir.join("bad.json"), None).unwrap_err();
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(err.contains("bad.json: paste_last: \"v\" needs a modifier"), "{err}");
    }
}
