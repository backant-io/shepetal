//! Hold vs double-tap on one key. Pure: feed it events with millisecond timestamps.
//!
//! Recording starts on the first press so push-to-talk feels instant. A short tap keeps
//! recording for `double_tap_ms`; a second press inside that window switches to hands-free,
//! otherwise the tap is too short and nothing is transcribed. Any other key while the hotkey
//! is down cancels, because fn is a modifier and fn+F1 (brightness) must not start a dictation.

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Event {
    Down(u64),
    Up(u64),
    /// Another key was pressed.
    Other,
    /// Clock tick, so an expired tap window ends as too short without waiting for fn. The
    /// daemon feeds one after every key event and every 50 ms without one.
    Tick(u64),
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Action {
    Start,
    /// Stop and transcribe.
    Stop,
    /// Stop without transcribing. The audio is kept as `*.cancelled.wav`.
    Cancel,
    /// Released before the hold threshold with no second tap: nothing is transcribed or
    /// inserted, the audio is kept as `*.tooshort.wav` and the short-press hint shows.
    TooShort,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum State {
    Idle,
    Pressed(u64),
    Tapped(u64),
    HandsFree,
}

#[derive(Debug)]
pub struct Gesture {
    /// A press at least this long is push-to-talk; shorter is a tap.
    pub hold_ms: u64,
    /// Max gap between the first release and the second press of a double tap.
    pub double_tap_ms: u64,
    state: State,
}

// Same as the Mac (ShepetalCore/FnGesture.swift), so a press gives the same result on both.
// 500 ms is Wispr's debounce for the double-tap window and the short-tap discard
// (docs/re/dictation-input.md, section 2.3).
pub const HOLD_MS: u64 = 500;
pub const DOUBLE_TAP_MS: u64 = 500;

impl Default for Gesture {
    fn default() -> Self {
        Gesture { hold_ms: HOLD_MS, double_tap_ms: DOUBLE_TAP_MS, state: State::Idle }
    }
}

impl Gesture {
    /// Recording hands-free after a double tap: the 🤫 ring is orange instead of red.
    pub fn hands_free(&self) -> bool {
        self.state == State::HandsFree
    }

    pub fn feed(&mut self, ev: Event) -> Vec<Action> {
        use Action::*;
        use State::*;
        let (next, out) = match (self.state, ev) {
            (Idle, Event::Down(t)) => (Pressed(t), vec![Start]),
            (Pressed(t0), Event::Up(t)) if t - t0 >= self.hold_ms => (Idle, vec![Stop]),
            (Pressed(_), Event::Up(t)) => (Tapped(t), vec![]),
            (Pressed(_), Event::Other) => (Idle, vec![Cancel]),
            (Tapped(t0), Event::Down(t)) if t - t0 <= self.double_tap_ms => (HandsFree, vec![]),
            (Tapped(_), Event::Down(t)) => (Pressed(t), vec![TooShort, Start]),
            // At the deadline, as the Mac's `FnGesture.tick` (`>=`).
            (Tapped(t0), Event::Tick(t)) if t - t0 >= self.double_tap_ms => (Idle, vec![TooShort]),
            // The release of the second tap, and typing while hands-free, keep recording. Typing
            // after a tap is not a chord (fn is already up), so the tap still ends as too short.
            (HandsFree, Event::Down(_)) => (Idle, vec![Stop]),
            (s, _) => (s, vec![]),
        };
        self.state = next;
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Action::*;
    use Event::*;

    fn run(evs: &[Event]) -> Vec<Action> {
        let mut g = Gesture::default();
        evs.iter().flat_map(|e| g.feed(*e)).collect()
    }

    // Literal numbers on purpose, matching the Mac's FnGestureTests: 499 ms is a tap, 500 ms a
    // hold, and a second press up to 500 ms after the release is a double tap. Moving these
    // changes how the key feels and splits the platforms, so it must break a test.
    #[test]
    fn hold_of_500ms_is_push_to_talk() {
        assert_eq!(run(&[Down(0), Up(500)]), vec![Start, Stop]);
    }

    #[test]
    fn release_at_499ms_is_a_tap_not_a_stop() {
        // A tap must not transcribe: the user may be starting a double tap.
        assert_eq!(run(&[Down(0), Up(499)]), vec![Start]);
    }

    #[test]
    fn double_tap_gap_is_500ms() {
        assert_eq!(run(&[Down(0), Up(100), Down(600), Down(1000)]), vec![Start, Stop]);
        assert_eq!(run(&[Down(0), Up(100), Down(601)]), vec![Start, TooShort, Start]);
    }

    #[test]
    fn single_tap_is_too_short_once_window_expires() {
        // Goal rule 2: nothing is transcribed, and only after the double-tap window has passed.
        assert_eq!(run(&[Down(0), Up(100), Tick(599)]), vec![Start]);
        assert_eq!(run(&[Down(0), Up(100), Tick(600)]), vec![Start, TooShort], "at the deadline, as on the Mac");
        assert_eq!(run(&[Down(0), Up(100), Tick(600), Tick(5000)]), vec![Start, TooShort], "settled once");
    }

    #[test]
    fn typing_after_a_tap_is_still_too_short() {
        // fn was released before the other key, so this is a short press, not an fn chord.
        assert_eq!(run(&[Down(0), Up(100), Other, Tick(601)]), vec![Start, TooShort]);
    }

    #[test]
    fn double_tap_inside_window_is_hands_free_until_next_press() {
        let t = 100;
        let evs = [Down(0), Up(t), Down(t + DOUBLE_TAP_MS), Up(t + DOUBLE_TAP_MS + 50),
                   Tick(10_000), Other, Down(20_000), Up(20_050)];
        assert_eq!(run(&evs), vec![Start, Stop]);
    }

    #[test]
    fn second_press_after_window_starts_fresh() {
        let t = 100;
        assert_eq!(run(&[Down(0), Up(t), Down(t + DOUBLE_TAP_MS + 1)]), vec![Start, TooShort, Start]);
    }

    #[test]
    fn chord_with_another_key_cancels() {
        // fn + F1 is a brightness key, not a dictation, and not a too-short press either.
        assert_eq!(run(&[Down(0), Other, Up(1000), Tick(5000)]), vec![Start, Cancel]);
    }
}
