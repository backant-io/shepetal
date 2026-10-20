//! One dictation, from the gesture's decision to the text at the cursor. Pure: the mic, the
//! audio store, the insert step and the 🤫 overlay come in as the small traits below, so the
//! wiring is tested here with fakes and `win.rs` plugs in the real crates. Speech-to-text runs
//! on its own thread: `action` hands back the samples to transcribe, and the caller passes the
//! result to `transcribed`.

/// What the core gesture decided about the hotkey (Ctrl+Win by default).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Action {
    Start,
    /// A double tap locked the recording on (hands-free).
    HandsFree,
    Stop,
    Cancel,
    TooShort,
}

/// What shows at the 🤫 in the bottom-left corner (goal rule 3).
#[derive(Debug, Clone, PartialEq)]
pub enum Overlay {
    Idle,
    Recording,
    HandsFree,
    Processing,
    /// Text next to the 🤫 for `HINT_MS`.
    Hint(String),
    Error(String),
}

/// Why a clip was kept. Every recording is kept (goal rule 4); cancelled and too-short ones are
/// marked as such.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Kept {
    Dictation,
    Cancelled,
    TooShort,
}

pub trait Mic {
    fn start(&mut self) -> Result<(), String>;
    /// The 16 kHz mono samples recorded since `start`.
    fn stop(&mut self) -> Vec<f32>;
}

pub trait Store {
    fn keep(&mut self, samples: &[f32], why: Kept) -> Result<(), String>;
}

/// Goal rule 8: remember the focused window at the start, paste only into that same window,
/// otherwise leave the text on the clipboard.
pub trait Insert {
    fn remember_focus(&mut self);
    /// True if pasted. False means the text was left on the clipboard.
    fn insert(&mut self, text: &str) -> bool;
}

pub trait Show {
    fn show(&mut self, overlay: &Overlay);
}

pub const HINT_MS: u64 = 2000;
/// Our own wording (goal rule 2). Windows keyboards have no fn, so the hotkey is Ctrl+Win.
pub const SHORT_PRESS_HINT: &str = "Hold Ctrl+Win to talk · double-tap for hands-free";
pub const CLIPBOARD_HINT: &str = "Copied · press Ctrl+V to paste";

#[derive(Debug, Clone, Copy, PartialEq)]
enum State {
    Idle,
    Recording,
    Processing,
}

pub struct Flow<M, S, I, O> {
    pub mic: M,
    pub store: S,
    pub insert: I,
    pub show: O,
    /// Text clean-up from the core crate, applied before insertion.
    pub rules: fn(&str) -> String,
    state: State,
    hint_until: Option<u64>,
    /// An error to show once the text is in, so a failed save never costs the dictation.
    pending: Option<String>,
}

impl<M: Mic, S: Store, I: Insert, O: Show> Flow<M, S, I, O> {
    pub fn new(mic: M, store: S, insert: I, mut show: O, rules: fn(&str) -> String) -> Self {
        show.show(&Overlay::Idle);
        Flow { mic, store, insert, show, rules, state: State::Idle, hint_until: None, pending: None }
    }

    /// Feed one gesture action at `now` (ms). Returns the samples to transcribe after a Stop.
    pub fn action(&mut self, action: Action, now: u64) -> Option<Vec<f32>> {
        use Action::*;
        match (self.state, action) {
            (State::Idle, Start) => {
                self.insert.remember_focus();
                match self.mic.start() {
                    Ok(()) => {
                        self.state = State::Recording;
                        self.set(Overlay::Recording, None);
                    }
                    Err(e) => self.set(Overlay::Error(e), Some(now)),
                }
            }
            (State::Recording, HandsFree) => self.set(Overlay::HandsFree, None),
            (State::Recording, Stop) => {
                let samples = self.mic.stop();
                self.pending = self.store.keep(&samples, Kept::Dictation).err();
                self.state = State::Processing;
                self.set(Overlay::Processing, None);
                return Some(samples);
            }
            (State::Recording, Cancel | TooShort) => {
                let samples = self.mic.stop();
                let why = if action == Cancel { Kept::Cancelled } else { Kept::TooShort };
                self.state = State::Idle;
                match self.store.keep(&samples, why) {
                    Err(e) => self.set(Overlay::Error(e), Some(now)),
                    Ok(()) if why == Kept::TooShort => self.set(Overlay::Hint(SHORT_PRESS_HINT.into()), Some(now)),
                    Ok(()) => self.set(Overlay::Idle, None),
                }
            }
            // A press while the last dictation is still transcribing is ignored, as in Wispr
            // (docs/re/dictation-input.md 2.3). Its release then finds nothing to stop.
            _ => {}
        }
        None
    }

    /// The transcript of the samples the last Stop returned.
    pub fn transcribed(&mut self, text: Result<String, String>, now: u64) {
        if self.state != State::Processing {
            return;
        }
        self.state = State::Idle;
        let text = text.map(|t| (self.rules)(&t));
        let pasted = match &text {
            Ok(t) if !t.is_empty() => self.insert.insert(t),
            _ => true,
        };
        match (text, self.pending.take()) {
            (Err(e), _) | (Ok(_), Some(e)) => self.set(Overlay::Error(e), Some(now)),
            (Ok(_), None) if !pasted => self.set(Overlay::Hint(CLIPBOARD_HINT.into()), Some(now)),
            (Ok(_), None) => self.set(Overlay::Idle, None),
        }
    }

    /// Clock tick: a hint or error goes back to the idle 🤫 after `HINT_MS`.
    pub fn tick(&mut self, now: u64) {
        if self.hint_until.is_some_and(|t| now >= t) {
            self.set(Overlay::Idle, None);
        }
    }

    fn set(&mut self, overlay: Overlay, since: Option<u64>) {
        self.hint_until = since.map(|t| t + HINT_MS);
        self.show.show(&overlay);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    /// Everything the fakes saw, in order.
    type Log = Rc<RefCell<Vec<String>>>;

    struct FakeMic(Log, Result<(), String>);
    impl Mic for FakeMic {
        fn start(&mut self) -> Result<(), String> {
            self.0.borrow_mut().push("mic start".into());
            self.1.clone()
        }
        fn stop(&mut self) -> Vec<f32> {
            self.0.borrow_mut().push("mic stop".into());
            vec![0.5; 16]
        }
    }
    struct FakeStore(Log, Result<(), String>);
    impl Store for FakeStore {
        fn keep(&mut self, samples: &[f32], why: Kept) -> Result<(), String> {
            self.0.borrow_mut().push(format!("keep {} {why:?}", samples.len()));
            self.1.clone()
        }
    }
    struct FakeInsert(Log, bool);
    impl Insert for FakeInsert {
        fn remember_focus(&mut self) {
            self.0.borrow_mut().push("remember focus".into());
        }
        fn insert(&mut self, text: &str) -> bool {
            self.0.borrow_mut().push(format!("insert {text}"));
            self.1
        }
    }
    struct FakeShow(Log);
    impl Show for FakeShow {
        fn show(&mut self, overlay: &Overlay) {
            self.0.borrow_mut().push(format!("show {overlay:?}"));
        }
    }

    fn flow(mic: Result<(), String>, store: Result<(), String>, pastes: bool) -> (Flow<FakeMic, FakeStore, FakeInsert, FakeShow>, Log) {
        let log = Log::default();
        let f = Flow::new(FakeMic(log.clone(), mic), FakeStore(log.clone(), store), FakeInsert(log.clone(), pastes), FakeShow(log.clone()), |t| t.trim().to_string());
        log.borrow_mut().clear();
        (f, log)
    }

    fn take(log: &Log) -> Vec<String> {
        std::mem::take(&mut *log.borrow_mut())
    }

    #[test]
    fn hold_records_keeps_the_audio_then_pastes_into_the_window_that_kept_focus() {
        let (mut f, log) = flow(Ok(()), Ok(()), true);
        assert_eq!(f.action(Action::Start, 0), None);
        // Rule 8: the focused window is taken before the mic starts, not when the text is ready.
        assert_eq!(take(&log), ["remember focus", "mic start", "show Recording"]);
        let samples = f.action(Action::Stop, 900).expect("a stop hands the samples to STT");
        assert_eq!(samples.len(), 16);
        // Rule 4: the clip is kept before it is transcribed, so a crash in STT still keeps it.
        assert_eq!(take(&log), ["mic stop", "keep 16 Dictation", "show Processing"]);
        f.transcribed(Ok("  hello world ".into()), 1100);
        assert_eq!(take(&log), ["insert hello world", "show Idle"], "core rules run before insert");
    }

    #[test]
    fn focus_moved_leaves_the_text_on_the_clipboard_with_the_ctrl_v_hint() {
        let (mut f, log) = flow(Ok(()), Ok(()), false);
        f.action(Action::Start, 0);
        f.action(Action::Stop, 900);
        take(&log);
        f.transcribed(Ok("hi".into()), 1000);
        assert_eq!(take(&log), ["insert hi", format!("show Hint({CLIPBOARD_HINT:?})").as_str()]);
        f.tick(2999);
        assert!(take(&log).is_empty(), "the hint stays for 2 s");
        f.tick(3000);
        assert_eq!(take(&log), ["show Idle"]);
    }

    #[test]
    fn too_short_and_cancelled_are_kept_but_never_transcribed() {
        // Rules 2 and 4: nothing is transcribed or inserted, the audio is still kept and marked.
        let (mut f, log) = flow(Ok(()), Ok(()), true);
        f.action(Action::Start, 0);
        take(&log);
        assert_eq!(f.action(Action::TooShort, 600), None);
        assert_eq!(take(&log), ["mic stop", "keep 16 TooShort", format!("show Hint({SHORT_PRESS_HINT:?})").as_str()]);
        f.action(Action::Start, 5000);
        take(&log);
        assert_eq!(f.action(Action::Cancel, 5200), None);
        assert_eq!(take(&log), ["mic stop", "keep 16 Cancelled", "show Idle"]);
    }

    #[test]
    fn short_press_hint_names_the_windows_hotkey() {
        // Windows keyboards don't report fn, so the default is Ctrl+Win, as in Wispr's Windows app.
        assert!(SHORT_PRESS_HINT.starts_with("Hold Ctrl+Win to talk"));
    }

    #[test]
    fn hands_free_shows_its_own_state() {
        let (mut f, log) = flow(Ok(()), Ok(()), true);
        f.action(Action::Start, 0);
        f.action(Action::HandsFree, 300);
        assert_eq!(take(&log).last().unwrap(), "show HandsFree");
    }

    #[test]
    fn a_press_while_transcribing_is_ignored() {
        let (mut f, log) = flow(Ok(()), Ok(()), true);
        f.action(Action::Start, 0);
        f.action(Action::Stop, 900);
        take(&log);
        assert_eq!(f.action(Action::Start, 950), None);
        assert_eq!(f.action(Action::Stop, 1500), None);
        assert!(take(&log).is_empty(), "the mic must not restart mid-transcription");
        f.transcribed(Ok("one".into()), 2000);
        f.transcribed(Ok("two".into()), 2100);
        assert_eq!(take(&log), ["insert one", "show Idle"], "one transcript per stop");
    }

    #[test]
    fn mic_error_shows_and_clears() {
        let (mut f, log) = flow(Err("No microphone".into()), Ok(()), true);
        f.action(Action::Start, 0);
        assert_eq!(take(&log), ["remember focus", "mic start", "show Error(\"No microphone\")"]);
        assert_eq!(f.action(Action::Stop, 900), None, "nothing to stop");
        f.tick(2000);
        assert_eq!(take(&log), ["show Idle"]);
    }

    #[test]
    fn a_failed_save_still_inserts_the_text_then_says_so() {
        let (mut f, log) = flow(Ok(()), Err("Disk full".into()), true);
        f.action(Action::Start, 0);
        f.action(Action::Stop, 900);
        take(&log);
        f.transcribed(Ok("keep me".into()), 1000);
        assert_eq!(take(&log), ["insert keep me", "show Error(\"Disk full\")"]);
    }

    #[test]
    fn empty_or_failed_transcript_inserts_nothing() {
        let (mut f, log) = flow(Ok(()), Ok(()), true);
        f.action(Action::Start, 0);
        f.action(Action::Stop, 900);
        take(&log);
        f.transcribed(Ok("   ".into()), 1000);
        assert_eq!(take(&log), ["show Idle"]);
        f.action(Action::Start, 2000);
        f.action(Action::Stop, 2900);
        take(&log);
        f.transcribed(Err("Model missing".into()), 3000);
        assert_eq!(take(&log), ["show Error(\"Model missing\")"]);
    }
}
