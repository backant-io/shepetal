//! Ctrl+Win gestures, ported from the Mac (Sources/ShepetalCore/FnGesture.swift) with the same timings, so a
//! press gives the same result on every platform: hold Ctrl+Win to talk, double-tap it or press Ctrl+Win+Space
//! for hands-free, a tap ends hands-free, Esc cancels, and a press shorter than the hold threshold with no
//! second tap is dropped. Ctrl+Win and Ctrl+Win+Space are Wispr's Windows defaults (docs/re/dictation-input.md 1).
//!
//! Recording starts on the first press so push-to-talk feels instant. Times are milliseconds on any monotonic
//! clock (GetTickCount64). The shell calls `tick` at `deadline`.

/// What the shell does after a key event or a timer tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Open the mic: recording begins on the first press.
    Start,
    /// Keep recording without holding the keys: a second tap inside the window, or Space during the hold.
    /// The shell swallows that Space, since Windows maps Ctrl+Win+Space to the previous input language.
    LockHandsFree,
    /// Transcribe and insert.
    Stop,
    /// Nothing is transcribed or inserted. The audio is kept, marked too short, and `SHORT_PRESS_HINT` shows.
    TooShort,
    /// Nothing is transcribed. The audio is kept, marked cancelled. No hint. Esc, or Ctrl+Win used as a
    /// shortcut (Ctrl+Win+Left switches the virtual desktop).
    Cancel,
}

/// The keys the gesture tells apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Ctrl,
    Win,
    Space,
    Esc,
    Other,
}

impl Key {
    /// From the `vkCode` of a low-level keyboard hook (KBDLLHOOKSTRUCT). The shell skips events it injected
    /// itself (LLKHF_INJECTED), so its own Ctrl+V does not count as the user pressing Ctrl.
    pub fn from_vk(vk: u32) -> Key {
        match vk {
            0x11 | 0xA2 | 0xA3 => Key::Ctrl, // VK_CONTROL, VK_LCONTROL, VK_RCONTROL
            0x5B | 0x5C => Key::Win,         // VK_LWIN, VK_RWIN
            0x20 => Key::Space,              // VK_SPACE
            0x1B => Key::Esc,                // VK_ESCAPE
            _ => Key::Other,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Idle,
    Holding { since: u64 },
    AwaitingSecondTap { deadline: u64 },
    HandsFree,
}

/// A press at least this long is push-to-talk; shorter is a tap. Same as the Mac and Linux.
pub const HOLD_MS: u64 = 500;
/// Max gap between the first release and the second press of a double tap.
pub const DOUBLE_TAP_MS: u64 = 500;
/// Another key in the first second of a hold makes Ctrl+Win a shortcut, not a dictation
/// (docs/re/dictation-input.md 2.3, "Chord collision").
pub const CHORD_WINDOW_MS: u64 = 1000;

/// Shown next to the 🤫 indicator after a too-short press. Our own wording, as on the Mac and Linux.
pub const SHORT_PRESS_HINT: &str = "Hold Ctrl+Win to talk · double-tap for hands-free";
/// How long the hint shows.
pub const HINT_MS: u64 = 2000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Gesture {
    pub hold_ms: u64,
    pub double_tap_ms: u64,
    pub chord_window_ms: u64,
    state: State,
    ctrl: bool,
    win: bool,
}

impl Default for Gesture {
    fn default() -> Self {
        Gesture {
            hold_ms: HOLD_MS,
            double_tap_ms: DOUBLE_TAP_MS,
            chord_window_ms: CHORD_WINDOW_MS,
            state: State::Idle,
            ctrl: false,
            win: false,
        }
    }
}

impl Gesture {
    pub fn state(&self) -> State {
        self.state
    }

    /// When the shell must call `tick` to settle a short press.
    pub fn deadline(&self) -> Option<u64> {
        match self.state {
            State::AwaitingSecondTap { deadline } => Some(deadline),
            _ => None,
        }
    }

    /// A key went down, auto-repeat included.
    pub fn key_down(&mut self, key: Key, t: u64) -> Vec<Action> {
        match key {
            Key::Ctrl | Key::Win => {
                let was = self.chord();
                self.set(key, true);
                if !was && self.chord() { self.chord_down(t) } else { vec![] }
            }
            // Chord promotion: Ctrl+Win+Space is the hands-free shortcut, so Space during a hold locks it.
            // A hold always has the chord down; Space at any other time is typing.
            Key::Space => match self.state {
                State::Holding { .. } => {
                    self.state = State::HandsFree;
                    vec![Action::LockHandsFree]
                }
                _ => vec![],
            },
            Key::Esc => {
                if self.state == State::Idle {
                    return vec![];
                }
                self.state = State::Idle;
                vec![Action::Cancel]
            }
            Key::Other => match self.state {
                State::Holding { since } if t.saturating_sub(since) < self.chord_window_ms => {
                    self.state = State::Idle;
                    vec![Action::Cancel]
                }
                _ => vec![],
            },
        }
    }

    /// A key went up. If the hook missed a key-up (the secure desktop takes Ctrl+Alt+Del), the shell calls
    /// this for Ctrl and Win when it gets the desktop back, so a stale Ctrl does not turn Win into the chord.
    pub fn key_up(&mut self, key: Key, t: u64) -> Vec<Action> {
        let was = self.chord();
        self.set(key, false);
        if was && !self.chord() { self.chord_up(t) } else { vec![] }
    }

    pub fn tick(&mut self, t: u64) -> Vec<Action> {
        match self.state {
            State::AwaitingSecondTap { deadline } if t >= deadline => {
                self.state = State::Idle;
                vec![Action::TooShort]
            }
            _ => vec![],
        }
    }

    /// Ends whatever is running without a result (errors such as a mic that does not open). Held keys stay
    /// held, so their auto-repeat does not start a new recording.
    pub fn reset(&mut self) {
        self.state = State::Idle;
    }

    fn chord(&self) -> bool {
        self.ctrl && self.win
    }

    fn set(&mut self, key: Key, down: bool) {
        match key {
            Key::Ctrl => self.ctrl = down,
            Key::Win => self.win = down,
            _ => {}
        }
    }

    fn chord_down(&mut self, t: u64) -> Vec<Action> {
        use Action::*;
        let (next, out) = match self.state {
            State::Idle => (State::Holding { since: t }, vec![Start]),
            State::AwaitingSecondTap { deadline } if t <= deadline => (State::HandsFree, vec![LockHandsFree]),
            // The tick was late: settle the old short press, then this press starts a new one.
            State::AwaitingSecondTap { .. } => (State::Holding { since: t }, vec![TooShort, Start]),
            State::HandsFree => (State::Idle, vec![Stop]),
            // A hold already has the chord down, so this cannot be a new press.
            s @ State::Holding { .. } => (s, vec![]),
        };
        self.state = next;
        out
    }

    fn chord_up(&mut self, t: u64) -> Vec<Action> {
        let State::Holding { since } = self.state else { return vec![] };
        if t.saturating_sub(since) < self.hold_ms {
            self.state = State::AwaitingSecondTap { deadline: t + self.double_tap_ms };
            return vec![];
        }
        self.state = State::Idle;
        vec![Action::Stop]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Action::*;
    use Key::*;

    fn press(g: &mut Gesture, t: u64) -> Vec<Action> {
        [g.key_down(Ctrl, t), g.key_down(Win, t)].concat()
    }

    fn release(g: &mut Gesture, t: u64) -> Vec<Action> {
        [g.key_up(Win, t), g.key_up(Ctrl, t)].concat()
    }

    // The tests below mirror the Mac's FnGestureTests with literal numbers on purpose: 499 ms is a tap,
    // 500 ms a hold, and a second press up to 500 ms after the release is a double tap. Moving these changes
    // how the key feels and splits the platforms, so it must break a test.

    // Hold to talk: a press longer than the hold threshold records and transcribes on release.
    #[test]
    fn hold_talks_and_release_transcribes() {
        let mut g = Gesture::default();
        assert_eq!(press(&mut g, 10_000), vec![Start]);
        assert_eq!(release(&mut g, 10_600), vec![Stop]);
        assert_eq!(g.state(), State::Idle);
    }

    #[test]
    fn hold_threshold_boundary() {
        let mut g = Gesture::default();
        press(&mut g, 0);
        assert_eq!(release(&mut g, 499), vec![], "a 499 ms press must not transcribe yet");
        assert_eq!(g.deadline(), Some(999));

        let mut h = Gesture::default();
        press(&mut h, 0);
        assert_eq!(release(&mut h, 500), vec![Stop], "a 500 ms press is a hold");
    }

    // Too-short press (rule 2): nothing is transcribed or inserted; the shell shows the hint and keeps the audio.
    #[test]
    fn short_press_is_dropped_with_hint() {
        let mut g = Gesture::default();
        press(&mut g, 0);
        release(&mut g, 200);
        assert_eq!(g.tick(699), vec![], "still inside the double-tap window");
        assert_eq!(g.tick(700), vec![TooShort]);
        assert_eq!(g.state(), State::Idle);
        assert_eq!(g.tick(5000), vec![], "settled once");
    }

    #[test]
    fn hint_wording_and_duration() {
        assert!(SHORT_PRESS_HINT.contains("Hold Ctrl+Win"), "{SHORT_PRESS_HINT}");
        assert!(SHORT_PRESS_HINT.contains("double-tap"), "{SHORT_PRESS_HINT}");
        assert!((1500..=2500).contains(&HINT_MS), "about 2 s, rule 2");
    }

    // Double-tap: the second press inside the window locks hands-free; release does not stop it;
    // the next tap ends it and transcribes.
    #[test]
    fn double_tap_locks_hands_free_and_tap_ends_it() {
        let mut g = Gesture::default();
        press(&mut g, 0);
        release(&mut g, 100);
        assert_eq!(press(&mut g, 600), vec![LockHandsFree], "600 is the last ms of the window");
        assert_eq!(release(&mut g, 650), vec![], "release while locked keeps recording");
        assert_eq!(g.tick(10_000), vec![], "no short-press timer while locked");
        assert_eq!(press(&mut g, 30_000), vec![Stop]);
        assert_eq!(release(&mut g, 30_100), vec![]);
        assert_eq!(g.state(), State::Idle);
    }

    // A second press just after the window is not a double-tap: the first press is too short
    // and the new press starts a fresh hold.
    #[test]
    fn second_press_after_window_is_new_hold() {
        let mut g = Gesture::default();
        press(&mut g, 0);
        release(&mut g, 100);
        assert_eq!(press(&mut g, 601), vec![TooShort, Start]);
        assert_eq!(release(&mut g, 2000), vec![Stop]);
    }

    // Windows auto-repeats the last key held down, modifiers too; a repeat is not a new press.
    #[test]
    fn repeated_down_while_holding_is_ignored() {
        let mut g = Gesture::default();
        press(&mut g, 0);
        assert_eq!(g.key_down(Ctrl, 100), vec![]);
        assert_eq!(g.key_down(Win, 130), vec![]);
        assert_eq!(release(&mut g, 1000), vec![Stop]);

        // Holding the second tap of a double tap repeats Win; that must not end hands-free.
        let mut h = Gesture::default();
        press(&mut h, 0);
        release(&mut h, 100);
        assert_eq!(press(&mut h, 300), vec![LockHandsFree]);
        assert_eq!(h.key_down(Win, 800), vec![]);
        assert_eq!(h.state(), State::HandsFree);
    }

    // Ctrl+Win is also part of Windows shortcuts: Ctrl+Win+Left/Right/D/F4 for virtual desktops,
    // Ctrl+Win+O, Ctrl+Win+Enter. Another key in the first second of a hold means a shortcut, so nothing
    // is transcribed or pasted (docs/re/dictation-input.md 2.3, "Chord collision").
    #[test]
    fn shortcut_with_ctrl_win_cancels() {
        let mut g = Gesture::default();
        press(&mut g, 0);
        assert_eq!(g.key_down(Other, 200), vec![Cancel]);
        assert_eq!(g.key_down(Other, 300), vec![], "key repeat after the cancel");
        assert_eq!(release(&mut g, 800), vec![], "a long Ctrl+Win+Left must not transcribe");
        assert_eq!(g.deadline(), None, "no short-press hint either");
        assert_eq!(g.state(), State::Idle);

        let mut quick = Gesture::default();
        press(&mut quick, 0);
        assert_eq!(quick.key_down(Other, 50), vec![Cancel], "quick Ctrl+Win+D");
        assert_eq!(release(&mut quick, 100), vec![]);
        assert_eq!(quick.tick(5000), vec![]);

        let mut edge = Gesture::default();
        press(&mut edge, 0);
        assert_eq!(edge.key_down(Other, 999), vec![Cancel], "999 ms is still inside the chord window");
    }

    // After the first second the user is talking; a key pressed then does not throw the dictation away.
    // Hands-free is not a held chord at all.
    #[test]
    fn keys_after_the_chord_window_or_in_hands_free_keep_recording() {
        let mut g = Gesture::default();
        press(&mut g, 0);
        assert_eq!(g.key_down(Other, 1000), vec![]);
        assert_eq!(release(&mut g, 3000), vec![Stop]);

        let mut h = Gesture::default();
        press(&mut h, 0);
        release(&mut h, 100);
        press(&mut h, 300);
        assert_eq!(h.key_down(Other, 400), vec![]);
        assert_eq!(h.state(), State::HandsFree);
        assert_eq!(h.key_down(Other, 9000), vec![]);
    }

    // Typing after a tap is not a chord (the keys are already up), so the tap still ends as too short.
    #[test]
    fn typing_after_a_tap_is_still_too_short() {
        let mut g = Gesture::default();
        press(&mut g, 0);
        release(&mut g, 100);
        assert_eq!(g.key_down(Other, 200), vec![]);
        assert_eq!(g.tick(600), vec![TooShort]);
    }

    #[test]
    fn key_classification() {
        assert_eq!(Key::from_vk(0xA2), Ctrl, "VK_LCONTROL");
        assert_eq!(Key::from_vk(0xA3), Ctrl, "VK_RCONTROL");
        assert_eq!(Key::from_vk(0x11), Ctrl, "VK_CONTROL");
        assert_eq!(Key::from_vk(0x5B), Win, "VK_LWIN");
        assert_eq!(Key::from_vk(0x5C), Win, "VK_RWIN");
        assert_eq!(Key::from_vk(0x20), Space);
        assert_eq!(Key::from_vk(0x1B), Esc);
        // Shift and Alt are not the chord: Ctrl+Win+Alt is a different shortcut.
        for vk in [0x10, 0xA0, 0xA1, 0x12, 0xA4, 0xA5, 0x25, 0x27, 0x44, 0x5D] {
            assert_eq!(Key::from_vk(vk), Other, "{vk:#x}");
        }
    }

    // The tests below are Windows-only: the hotkey is two keys, and Space and Esc have their own jobs.

    // Neither key alone is the hotkey (Ctrl+C, Win+E stay theirs), and the order they go down does not matter.
    #[test]
    fn chord_needs_both_keys_in_either_order() {
        let mut g = Gesture::default();
        assert_eq!(g.key_down(Ctrl, 0), vec![]);
        assert_eq!(g.key_up(Ctrl, 900), vec![]);
        assert_eq!(g.key_down(Win, 1000), vec![]);
        assert_eq!(g.key_up(Win, 1900), vec![]);
        assert_eq!(g.tick(9000), vec![]);
        assert_eq!(g.state(), State::Idle);

        assert_eq!(g.key_down(Win, 10_000), vec![]);
        assert_eq!(g.key_down(Ctrl, 10_100), vec![Start], "the hold starts when the second key goes down");
        assert_eq!(g.key_up(Win, 10_599), vec![], "letting go of either key ends the press: 499 ms is a tap");
        assert_eq!(g.deadline(), Some(11_099));
    }

    // Ctrl+Win+Space starts hands-free at once; letting go keeps recording; the next tap ends it.
    #[test]
    fn ctrl_win_space_locks_hands_free() {
        let mut g = Gesture::default();
        assert_eq!(press(&mut g, 0), vec![Start]);
        assert_eq!(g.key_down(Space, 80), vec![LockHandsFree]);
        assert_eq!(g.key_down(Space, 600), vec![], "Space auto-repeat");
        assert_eq!(g.key_up(Space, 700), vec![]);
        assert_eq!(release(&mut g, 750), vec![]);
        assert_eq!(g.tick(5000), vec![]);
        assert_eq!(g.state(), State::HandsFree);
        assert_eq!(press(&mut g, 20_000), vec![Stop]);
        assert_eq!(g.key_down(Space, 20_050), vec![], "the chord is still down, but a stopped dictation stays stopped");
        assert_eq!(release(&mut g, 20_100), vec![]);
        assert_eq!(g.state(), State::Idle);
    }

    // Chord promotion: Space while talking turns a long hold into hands-free; Space is not the
    // "other key" that cancels.
    #[test]
    fn space_promotes_a_hold_at_any_time() {
        let mut g = Gesture::default();
        press(&mut g, 0);
        assert_eq!(g.key_down(Space, 3000), vec![LockHandsFree]);
        assert_eq!(release(&mut g, 3100), vec![], "no stop on release once locked");
        assert_eq!(g.state(), State::HandsFree);
    }

    // Space without Ctrl+Win is typing: it neither starts nor ends a dictation.
    #[test]
    fn space_without_the_chord_is_typing() {
        let mut g = Gesture::default();
        assert_eq!(g.key_down(Space, 0), vec![]);
        assert_eq!(g.state(), State::Idle);

        press(&mut g, 1000);
        release(&mut g, 1100);
        assert_eq!(g.key_down(Space, 1200), vec![], "after a tap the keys are up");
        assert_eq!(g.tick(1600), vec![TooShort]);

        press(&mut g, 5000);
        release(&mut g, 5100);
        press(&mut g, 5200);
        release(&mut g, 5300);
        assert_eq!(g.key_down(Space, 8000), vec![], "typing a space in hands-free");
        assert_eq!(g.state(), State::HandsFree);
    }

    // Esc dismisses whatever is recording: a hold, a tap waiting for its second press, hands-free.
    // The audio is kept as cancelled, and a cancelled tap is not reported as too short later.
    #[test]
    fn esc_cancels_any_recording() {
        let mut g = Gesture::default();
        press(&mut g, 0);
        assert_eq!(g.key_down(Esc, 2000), vec![Cancel], "after the chord window, unlike other keys");
        assert_eq!(release(&mut g, 2500), vec![]);

        press(&mut g, 10_000);
        release(&mut g, 10_100);
        assert_eq!(g.key_down(Esc, 10_200), vec![Cancel]);
        assert_eq!(g.tick(20_000), vec![]);

        press(&mut g, 30_000);
        g.key_down(Space, 30_100);
        release(&mut g, 30_200);
        assert_eq!(g.key_down(Esc, 60_000), vec![Cancel]);
        assert_eq!(g.state(), State::Idle);

        assert_eq!(g.key_down(Esc, 70_000), vec![], "Esc while idle belongs to the app");
    }

    // An error resets the gesture while the user may still hold the keys. Their auto-repeat must not start
    // another recording; a fresh press does.
    #[test]
    fn reset_keeps_held_keys_held() {
        let mut g = Gesture::default();
        press(&mut g, 0);
        g.reset();
        assert_eq!(g.state(), State::Idle);
        assert_eq!(g.key_down(Ctrl, 100), vec![]);
        assert_eq!(g.key_down(Win, 130), vec![]);
        assert_eq!(release(&mut g, 400), vec![]);
        assert_eq!(press(&mut g, 1000), vec![Start]);
    }
}
