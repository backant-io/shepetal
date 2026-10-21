//! Hotkey gestures, ported from the Mac (Sources/ShepetalCore/FnGesture.swift) with the same timings, so a
//! press gives the same result on every platform: hold the hotkey (Ctrl+Win by default, Wispr's Windows
//! default, docs/re/dictation-input.md 1) to talk, double-tap it or add Space for hands-free, a tap ends
//! hands-free, Esc cancels, and a press shorter than the hold threshold with no second tap is dropped.
//!
//! The input crate tracks which keys make up the hotkey and reports when all of them are down
//! (`hotkey_down`) and when one comes up (`hotkey_up`), plus Esc and the keys pressed while the hotkey is
//! held (`key_down`). Recording starts on the first press so push-to-talk feels instant. Times are
//! milliseconds on any monotonic clock. The shell calls `tick` at `deadline`.

/// What the shell does after a key event or a timer tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Open the mic: recording begins on the first press.
    Start,
    /// Keep recording without holding the hotkey: a second tap inside the window, or Space during the hold.
    LockHandsFree,
    /// Transcribe and insert.
    Stop,
    /// Nothing is transcribed or inserted. The audio is kept, marked too short, and `short_press_hint` shows.
    TooShort,
    /// Nothing is transcribed. The audio is kept, marked cancelled. No hint. Esc, or the hotkey used as part
    /// of a shortcut (Ctrl+Win+Left switches the virtual desktop).
    Cancel,
    /// One minute before the length cap: the shell shows `MAX_LENGTH_WARNING`. Recording goes on.
    WarnDuration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Idle,
    Holding { since: u64 },
    AwaitingSecondTap { deadline: u64 },
    HandsFree,
}

pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_SPACE: u16 = 0x20;

/// A press at least this long is push-to-talk; shorter is a tap. Same as the Mac and Linux.
pub const HOLD_MS: u64 = 500;
/// Max gap between the first release and the second press of a double tap.
pub const DOUBLE_TAP_MS: u64 = 500;
/// Another key in the first second of a hold makes the hotkey part of a shortcut, not a dictation
/// (docs/re/dictation-input.md 2.3, "Chord collision").
pub const CHORD_WINDOW_MS: u64 = 1000;
/// A dictation is stopped (and transcribed as usual) after 20 minutes, with a warning at 19, as in
/// Wispr and on the Mac and Linux.
pub const MAX_MS: u64 = 20 * 60_000;
pub const WARN_MS: u64 = 19 * 60_000;
/// Shown next to 🤫 at 19 minutes. Our own wording, as on Linux.
pub const MAX_LENGTH_WARNING: &str = "Recording stops in 1 minute";
/// How long the short-press hint shows (product rule 2: about 3 s, `Hint.seconds` on the Mac).
pub const HINT_MS: u64 = 3000;

/// Shown next to the 🤫 indicator after a too-short press. Our own wording, as on the Mac and Linux.
pub fn short_press_hint(hotkey: &str) -> String {
    format!("Hold {hotkey} to talk · double-tap for hands-free")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Gesture {
    pub hold_ms: u64,
    pub double_tap_ms: u64,
    pub chord_window_ms: u64,
    pub max_ms: u64,
    pub warn_ms: u64,
    state: State,
    /// When the running recording started (its first press), and whether its warning was given.
    started: u64,
    warned: bool,
}

impl Default for Gesture {
    fn default() -> Self {
        Gesture {
            hold_ms: HOLD_MS,
            double_tap_ms: DOUBLE_TAP_MS,
            chord_window_ms: CHORD_WINDOW_MS,
            max_ms: MAX_MS,
            warn_ms: WARN_MS,
            state: State::Idle,
            started: 0,
            warned: false,
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

    /// Every key of the hotkey is down.
    pub fn hotkey_down(&mut self, t: u64) -> Vec<Action> {
        use Action::*;
        let (next, out) = match self.state {
            State::Idle => (State::Holding { since: t }, vec![Start]),
            State::AwaitingSecondTap { deadline } if t <= deadline => (State::HandsFree, vec![LockHandsFree]),
            // The tick was late: settle the old short press, then this press starts a new one.
            State::AwaitingSecondTap { .. } => (State::Holding { since: t }, vec![TooShort, Start]),
            State::HandsFree => (State::Idle, vec![Stop]),
            s @ State::Holding { .. } => (s, vec![]), // a duplicate event
        };
        if out.last() == Some(&Start) {
            self.started = t;
            self.warned = false;
        }
        self.state = next;
        out
    }

    /// A key of the hotkey came up.
    pub fn hotkey_up(&mut self, t: u64) -> Vec<Action> {
        let State::Holding { since } = self.state else { return vec![] };
        if t.saturating_sub(since) < self.hold_ms {
            self.state = State::AwaitingSecondTap { deadline: t + self.double_tap_ms };
            return vec![];
        }
        self.state = State::Idle;
        vec![Action::Stop]
    }

    /// A key that is not part of the hotkey went down (a Windows VK code). Esc cancels whatever is recording.
    /// Space during a hold locks hands-free: hotkey+Space is the hands-free shortcut (chord promotion,
    /// docs/re/dictation-input.md 2.3). Any other key in the first `chord_window_ms` of a hold cancels.
    pub fn key_down(&mut self, vk: u16, t: u64) -> Vec<Action> {
        let out = match (vk, self.state) {
            (_, State::Idle) => return vec![],
            (VK_ESCAPE, _) => Action::Cancel,
            (VK_SPACE, State::Holding { .. }) => {
                self.state = State::HandsFree;
                return vec![Action::LockHandsFree];
            }
            (_, State::Holding { since }) if t.saturating_sub(since) < self.chord_window_ms => Action::Cancel,
            _ => return vec![],
        };
        self.state = State::Idle;
        vec![out]
    }

    pub fn tick(&mut self, t: u64) -> Vec<Action> {
        match self.state {
            State::AwaitingSecondTap { deadline } if t >= deadline => {
                self.state = State::Idle;
                vec![Action::TooShort]
            }
            State::Holding { .. } | State::HandsFree => {
                let long = t.saturating_sub(self.started);
                if long >= self.max_ms {
                    // A forced stop: transcribed and inserted like a release. The release that
                    // follows a hold then finds nothing to stop.
                    self.state = State::Idle;
                    vec![Action::Stop]
                } else if long >= self.warn_ms && !self.warned {
                    self.warned = true;
                    vec![Action::WarnDuration]
                } else {
                    vec![]
                }
            }
            _ => vec![],
        }
    }

    /// Ends whatever is running without a result (errors such as a mic that does not open).
    pub fn reset(&mut self) {
        self.state = State::Idle;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Action::*;

    const VK_LEFT: u16 = 0x25;
    const VK_D: u16 = 0x44;

    // The tests below mirror the Mac's FnGestureTests with literal numbers on purpose: 499 ms is a tap,
    // 500 ms a hold, and a second press up to 500 ms after the release is a double tap. Moving these changes
    // how the key feels and splits the platforms, so it must break a test.

    // Hold to talk: a press longer than the hold threshold records and transcribes on release.
    #[test]
    fn hold_talks_and_release_transcribes() {
        let mut g = Gesture::default();
        assert_eq!(g.hotkey_down(10_000), vec![Start]);
        assert_eq!(g.hotkey_up(10_600), vec![Stop]);
        assert_eq!(g.state(), State::Idle);
    }

    #[test]
    fn hold_threshold_boundary() {
        let mut g = Gesture::default();
        g.hotkey_down(0);
        assert_eq!(g.hotkey_up(499), vec![], "a 499 ms press must not transcribe yet");
        assert_eq!(g.deadline(), Some(999));

        let mut h = Gesture::default();
        h.hotkey_down(0);
        assert_eq!(h.hotkey_up(500), vec![Stop], "a 500 ms press is a hold");
    }

    // Too-short press (rule 2): nothing is transcribed or inserted; the shell shows the hint and keeps the audio.
    #[test]
    fn short_press_is_dropped_with_hint() {
        let mut g = Gesture::default();
        g.hotkey_down(0);
        g.hotkey_up(200);
        assert_eq!(g.tick(699), vec![], "still inside the double-tap window");
        assert_eq!(g.tick(700), vec![TooShort]);
        assert_eq!(g.state(), State::Idle);
        assert_eq!(g.tick(5000), vec![], "settled once");
    }

    #[test]
    fn hint_wording_and_duration() {
        assert_eq!(short_press_hint("Ctrl+Win"), "Hold Ctrl+Win to talk · double-tap for hands-free");
        assert_eq!(HINT_MS, 3000, "about 3 s, rule 2, as on the Mac");
    }

    // The input crate reports keys as Windows VK codes.
    #[test]
    fn vk_codes_are_the_windows_ones() {
        assert_eq!((VK_ESCAPE, VK_SPACE), (0x1B, 0x20));
    }

    // Double-tap: the second press inside the window locks hands-free; release does not stop it;
    // the next tap ends it and transcribes.
    #[test]
    fn double_tap_locks_hands_free_and_tap_ends_it() {
        let mut g = Gesture::default();
        g.hotkey_down(0);
        g.hotkey_up(100);
        assert_eq!(g.hotkey_down(600), vec![LockHandsFree], "600 is the last ms of the window");
        assert_eq!(g.hotkey_up(650), vec![], "release while locked keeps recording");
        assert_eq!(g.tick(10_000), vec![], "no short-press timer while locked");
        assert_eq!(g.hotkey_down(30_000), vec![Stop]);
        assert_eq!(g.hotkey_up(30_100), vec![]);
        assert_eq!(g.state(), State::Idle);
    }

    // A second press just after the window is not a double-tap: the first press is too short
    // and the new press starts a fresh hold.
    #[test]
    fn second_press_after_window_is_new_hold() {
        let mut g = Gesture::default();
        g.hotkey_down(0);
        g.hotkey_up(100);
        assert_eq!(g.hotkey_down(601), vec![TooShort, Start]);
        assert_eq!(g.hotkey_up(2000), vec![Stop]);
    }

    #[test]
    fn repeated_down_while_holding_is_ignored() {
        let mut g = Gesture::default();
        g.hotkey_down(0);
        assert_eq!(g.hotkey_down(100), vec![]);
        assert_eq!(g.hotkey_up(1000), vec![Stop]);
    }

    // Ctrl+Win is also part of Windows shortcuts: Ctrl+Win+Left/Right/D/F4 for virtual desktops,
    // Ctrl+Win+O, Ctrl+Win+Enter. Another key in the first second of a hold means a shortcut, so nothing
    // is transcribed or pasted (docs/re/dictation-input.md 2.3, "Chord collision").
    #[test]
    fn shortcut_with_the_hotkey_cancels() {
        let mut g = Gesture::default();
        g.hotkey_down(0);
        assert_eq!(g.key_down(VK_LEFT, 200), vec![Cancel]);
        assert_eq!(g.key_down(VK_LEFT, 300), vec![], "key repeat after the cancel");
        assert_eq!(g.hotkey_up(800), vec![], "a long Ctrl+Win+Left must not transcribe");
        assert_eq!(g.deadline(), None, "no short-press hint either");
        assert_eq!(g.state(), State::Idle);

        let mut quick = Gesture::default();
        quick.hotkey_down(0);
        assert_eq!(quick.key_down(VK_D, 50), vec![Cancel], "quick Ctrl+Win+D");
        assert_eq!(quick.hotkey_up(100), vec![]);
        assert_eq!(quick.tick(5000), vec![]);

        let mut edge = Gesture::default();
        edge.hotkey_down(0);
        assert_eq!(edge.key_down(VK_D, 999), vec![Cancel], "999 ms is still inside the chord window");
    }

    // After the first second the user is talking; a key pressed then does not throw the dictation away.
    // Hands-free is not a held chord at all.
    #[test]
    fn keys_after_the_chord_window_or_in_hands_free_keep_recording() {
        let mut g = Gesture::default();
        g.hotkey_down(0);
        assert_eq!(g.key_down(VK_D, 1000), vec![]);
        assert_eq!(g.hotkey_up(3000), vec![Stop]);

        let mut h = Gesture::default();
        h.hotkey_down(0);
        h.hotkey_up(100);
        h.hotkey_down(300);
        assert_eq!(h.key_down(VK_D, 400), vec![]);
        assert_eq!(h.state(), State::HandsFree);
        assert_eq!(h.key_down(VK_D, 9000), vec![]);
    }

    // Typing after a tap is not a chord (the hotkey is already up), so the tap still ends as too short.
    #[test]
    fn typing_after_a_tap_is_still_too_short() {
        let mut g = Gesture::default();
        g.hotkey_down(0);
        g.hotkey_up(100);
        assert_eq!(g.key_down(VK_D, 200), vec![]);
        assert_eq!(g.tick(600), vec![TooShort]);
    }

    // The tests below are for what the Mac's FnGesture on main does not have yet: Space and Esc.

    // Ctrl+Win+Space starts hands-free at once; letting go keeps recording; the next tap ends it.
    #[test]
    fn hotkey_and_space_lock_hands_free() {
        let mut g = Gesture::default();
        assert_eq!(g.hotkey_down(0), vec![Start]);
        assert_eq!(g.key_down(VK_SPACE, 80), vec![LockHandsFree]);
        assert_eq!(g.key_down(VK_SPACE, 600), vec![], "Space auto-repeat");
        assert_eq!(g.hotkey_up(750), vec![]);
        assert_eq!(g.tick(5000), vec![]);
        assert_eq!(g.state(), State::HandsFree);
        assert_eq!(g.hotkey_down(20_000), vec![Stop]);
        assert_eq!(g.key_down(VK_SPACE, 20_050), vec![], "a stopped dictation stays stopped");
        assert_eq!(g.hotkey_up(20_100), vec![]);
        assert_eq!(g.state(), State::Idle);
    }

    // Chord promotion: Space while talking turns a long hold into hands-free; Space is not the
    // "other key" that cancels.
    #[test]
    fn space_promotes_a_hold_at_any_time() {
        let mut g = Gesture::default();
        g.hotkey_down(0);
        assert_eq!(g.key_down(VK_SPACE, 3000), vec![LockHandsFree]);
        assert_eq!(g.hotkey_up(3100), vec![], "no stop on release once locked");
        assert_eq!(g.state(), State::HandsFree);
    }

    // Space outside a hold is typing: it neither starts, locks nor ends a dictation.
    #[test]
    fn space_outside_a_hold_does_nothing() {
        let mut g = Gesture::default();
        assert_eq!(g.key_down(VK_SPACE, 0), vec![]);
        assert_eq!(g.state(), State::Idle);

        g.hotkey_down(1000);
        g.hotkey_up(1100);
        assert_eq!(g.key_down(VK_SPACE, 1200), vec![], "after a tap the hotkey is up");
        assert_eq!(g.tick(1600), vec![TooShort]);

        g.hotkey_down(5000);
        g.hotkey_up(5100);
        g.hotkey_down(5200);
        g.hotkey_up(5300);
        assert_eq!(g.key_down(VK_SPACE, 8000), vec![], "a space in hands-free");
        assert_eq!(g.state(), State::HandsFree);
    }

    // Esc dismisses whatever is recording: a hold, a tap waiting for its second press, hands-free.
    // The audio is kept as cancelled, and a cancelled tap is not reported as too short later.
    #[test]
    fn esc_cancels_any_recording() {
        let mut g = Gesture::default();
        g.hotkey_down(0);
        assert_eq!(g.key_down(VK_ESCAPE, 2000), vec![Cancel], "after the chord window, unlike other keys");
        assert_eq!(g.hotkey_up(2500), vec![]);

        g.hotkey_down(10_000);
        g.hotkey_up(10_100);
        assert_eq!(g.key_down(VK_ESCAPE, 10_200), vec![Cancel]);
        assert_eq!(g.tick(20_000), vec![]);

        g.hotkey_down(30_000);
        g.key_down(VK_SPACE, 30_100);
        g.hotkey_up(30_200);
        assert_eq!(g.key_down(VK_ESCAPE, 60_000), vec![Cancel]);
        assert_eq!(g.state(), State::Idle);

        assert_eq!(g.key_down(VK_ESCAPE, 70_000), vec![], "Esc while idle belongs to the app");
    }

    // The length cap (Wispr: a warning at 19 min, a stop at 20), counted from the first press, in
    // hands-free and in a hold alike.
    #[test]
    fn dictation_warns_at_19_min_and_stops_at_20() {
        assert_eq!((MAX_MS, WARN_MS), (20 * 60_000, 19 * 60_000));
        let mut g = Gesture::default();
        g.hotkey_down(1000);
        g.hotkey_up(1100);
        assert_eq!(g.hotkey_down(1300), vec![LockHandsFree]);
        assert_eq!(g.tick(1000 + WARN_MS - 1), vec![]);
        assert_eq!(g.tick(1000 + WARN_MS), vec![WarnDuration], "from the first press, not the second");
        assert_eq!(g.tick(1000 + WARN_MS + 50), vec![], "warned once");
        assert_eq!(g.tick(1000 + MAX_MS - 1), vec![]);
        assert_eq!(g.tick(1000 + MAX_MS), vec![Stop]);
        assert_eq!(g.state(), State::Idle);
        assert_eq!(g.tick(1000 + MAX_MS + 50), vec![], "stopped once");
        assert_eq!(g.hotkey_down(2000 + MAX_MS), vec![Start], "the next press starts a new one");

        let mut hold = Gesture::default();
        hold.hotkey_down(0);
        assert_eq!(hold.tick(WARN_MS), vec![WarnDuration]);
        assert_eq!(hold.tick(MAX_MS), vec![Stop]);
        assert_eq!(hold.hotkey_up(MAX_MS + 5000), vec![], "the release after the cap stops nothing");

        // A new recording gets its own warning and its own 20 minutes.
        let mut again = Gesture::default();
        again.hotkey_down(0);
        again.tick(WARN_MS);
        again.hotkey_up(WARN_MS + 10);
        assert_eq!(again.hotkey_down(WARN_MS + 5000), vec![Start]);
        assert_eq!(again.tick(WARN_MS + 5000 + WARN_MS - 1), vec![]);
        assert_eq!(again.tick(WARN_MS + 5000 + WARN_MS), vec![WarnDuration]);
    }

    // An error ends the recording; a tap that was waiting must not turn into a too-short hint afterwards.
    #[test]
    fn reset_drops_a_pending_tap() {
        let mut g = Gesture::default();
        g.hotkey_down(0);
        g.hotkey_up(100);
        g.reset();
        assert_eq!(g.tick(600), vec![]);
        assert_eq!(g.hotkey_down(700), vec![Start], "a fresh press after the reset");
    }
}
