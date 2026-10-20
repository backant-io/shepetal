//! Hold vs double-tap on one key. Pure: feed it events with millisecond timestamps.
//!
//! Recording starts on the first press so push-to-talk feels instant. A short tap keeps
//! recording for `double_tap_ms`; a second press inside that window switches to hands-free,
//! otherwise the tap is cancelled. Any other key while the hotkey is down cancels, because
//! Right Ctrl is a modifier and Ctrl+C must not start a dictation.

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Event {
    Down(u64),
    Up(u64),
    /// Another key was pressed.
    Other,
    /// Clock tick, so an expired tap window cancels without waiting for a key.
    Tick(u64),
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Action {
    Start,
    /// Stop and transcribe.
    Stop,
    /// Stop and throw the audio away.
    Cancel,
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

pub const HOLD_MS: u64 = 300;
pub const DOUBLE_TAP_MS: u64 = 400;

impl Default for Gesture {
    fn default() -> Self {
        Gesture { hold_ms: HOLD_MS, double_tap_ms: DOUBLE_TAP_MS, state: State::Idle }
    }
}

impl Gesture {
    pub fn feed(&mut self, ev: Event) -> Vec<Action> {
        use Action::*;
        use State::*;
        let (next, out) = match (self.state, ev) {
            (Idle, Event::Down(t)) => (Pressed(t), vec![Start]),
            (Pressed(t0), Event::Up(t)) if t - t0 >= self.hold_ms => (Idle, vec![Stop]),
            (Pressed(_), Event::Up(t)) => (Tapped(t), vec![]),
            (Pressed(_), Event::Other) => (Idle, vec![Cancel]),
            (Tapped(t0), Event::Down(t)) if t - t0 <= self.double_tap_ms => (HandsFree, vec![]),
            (Tapped(_), Event::Down(t)) => (Pressed(t), vec![Cancel, Start]),
            (Tapped(t0), Event::Tick(t)) if t - t0 > self.double_tap_ms => (Idle, vec![Cancel]),
            (Tapped(_), Event::Other) => (Idle, vec![Cancel]),
            // The release of the second tap, and typing while hands-free, keep recording.
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

    #[test]
    fn hold_at_threshold_is_push_to_talk() {
        assert_eq!(run(&[Down(0), Up(HOLD_MS)]), vec![Start, Stop]);
    }

    #[test]
    fn release_just_under_threshold_is_a_tap_not_a_stop() {
        // A tap must not transcribe: the user may be starting a double tap.
        assert_eq!(run(&[Down(0), Up(HOLD_MS - 1)]), vec![Start]);
    }

    #[test]
    fn single_tap_cancels_once_window_expires() {
        let t = 100;
        assert_eq!(run(&[Down(0), Up(t), Tick(t + DOUBLE_TAP_MS)]), vec![Start]);
        assert_eq!(run(&[Down(0), Up(t), Tick(t + DOUBLE_TAP_MS + 1)]), vec![Start, Cancel]);
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
        assert_eq!(run(&[Down(0), Up(t), Down(t + DOUBLE_TAP_MS + 1)]), vec![Start, Cancel, Start]);
    }

    #[test]
    fn chord_with_another_key_cancels() {
        // Right Ctrl + C is a copy, not a dictation.
        assert_eq!(run(&[Down(0), Other, Up(1000)]), vec![Start, Cancel]);
    }
}
