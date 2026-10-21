//! One dictation, from the core gesture's action to the text at the cursor. Pure: the mic, the
//! audio store, the insert step and the 🤫 overlay come in as the small traits below, so the
//! wiring is tested here with fakes, and `win.rs` plugs in the audio, insert and input crates.
//! Speech-to-text runs on its own thread: `action` hands back the samples to transcribe, and the
//! caller passes the result to `transcribed`.

use input::{Key, KeyEvent, Mode};
use shepetal_core::gesture::{short_press_hint, Action, Gesture, HINT_MS, MAX_LENGTH_WARNING, VK_ESCAPE};
use shepetal_core::text;

/// The dictation hotkey. Windows keyboards don't report fn, so it is Ctrl+Win, the default of
/// Wispr's Windows app. `win.rs` parses it for the hook, and the short-press hint names it.
pub const HOTKEY: &str = "Ctrl+Win";

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
    /// The history: the text of the last dictation clip `keep` kept, as it was inserted.
    fn transcript(&mut self, text: &str) -> Result<(), String>;
}

/// Goal rule 8: remember the focused window at the start, paste only into that same window,
/// otherwise leave the text on the clipboard.
pub trait Insert {
    fn remember_focus(&mut self);
    /// Ok(None): pasted. Ok(Some(hint)): left on the clipboard, and `hint` says why and to press
    /// Ctrl+V. Err: the clipboard could not be written.
    fn insert(&mut self, text: &str) -> Result<Option<String>, String>;
}

/// The 🤫 overlay (input::Ui on Windows).
pub trait Show {
    fn mode(&mut self, mode: Mode);
    /// Text next to the 🤫 for `HINT_MS`.
    fn hint(&mut self, text: &str);
}

/// The text rules a transcript goes through before insertion: the cleanup, then spoken dates become
/// numbers (docs/text-rules.md: the date rule runs on the cleaned text).
pub fn rules(raw: &str) -> String {
    text::dates(&text::cleanup(raw))
}

/// Feeds one key event from the input hook into the core gesture.
pub fn feed(g: &mut Gesture, ev: KeyEvent, t: u64) -> Vec<Action> {
    match (ev.key, ev.down) {
        (Key::Hotkey, true) => g.hotkey_down(t),
        (Key::Hotkey, false) => g.hotkey_up(t),
        (Key::Esc, true) => g.key_down(VK_ESCAPE, t),
        (Key::Other(vk), true) => g.key_down(vk, t),
        _ => vec![],
    }
}

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
    /// When the error ring goes back to idle.
    error_until: Option<u64>,
    /// An error to show once the text is in, so a failed save never costs the dictation.
    pending: Option<String>,
}

impl<M: Mic, S: Store, I: Insert, O: Show> Flow<M, S, I, O> {
    pub fn new(mic: M, store: S, insert: I, show: O, rules: fn(&str) -> String) -> Self {
        Flow { mic, store, insert, show, rules, state: State::Idle, error_until: None, pending: None }
    }

    /// True while a clip is being recorded or transcribed.
    pub fn busy(&self) -> bool {
        self.state != State::Idle
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
                        self.mode(Mode::Recording);
                    }
                    Err(e) => self.error(&e, now),
                }
            }
            (State::Recording, LockHandsFree) => self.mode(Mode::HandsFree),
            (State::Recording, WarnDuration) => self.show.hint(MAX_LENGTH_WARNING),
            (State::Recording, Stop) => {
                let samples = self.mic.stop();
                self.pending = self.store.keep(&samples, Kept::Dictation).err();
                self.state = State::Processing;
                self.mode(Mode::Processing);
                return Some(samples);
            }
            (State::Recording, Cancel | TooShort) => {
                let samples = self.mic.stop();
                let why = if action == Cancel { Kept::Cancelled } else { Kept::TooShort };
                self.state = State::Idle;
                match self.store.keep(&samples, why) {
                    Err(e) => self.error(&e, now),
                    Ok(()) => {
                        self.mode(Mode::Idle);
                        if why == Kept::TooShort {
                            self.show.hint(&short_press_hint(HOTKEY));
                        }
                    }
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
        let inserted = match text.map(|t| (self.rules)(&t)) {
            Ok(t) if t.is_empty() => Ok(None),
            Ok(t) => {
                // Into the history first, so it is there even if the clipboard fails.
                if let Err(e) = self.store.transcript(&t) {
                    self.pending.get_or_insert(e);
                }
                self.insert.insert(&t)
            }
            Err(e) => Err(e),
        };
        match (inserted, self.pending.take()) {
            (Err(e), _) | (Ok(_), Some(e)) => self.error(&e, now),
            (Ok(hint), None) => {
                self.mode(Mode::Idle);
                if let Some(hint) = hint {
                    self.show.hint(&hint);
                }
            }
        }
    }

    /// Clock tick: the error ring goes back to idle after `HINT_MS`.
    pub fn tick(&mut self, now: u64) {
        if self.error_until.is_some_and(|t| now >= t) {
            self.mode(Mode::Idle);
        }
    }

    fn mode(&mut self, mode: Mode) {
        self.error_until = None;
        self.show.mode(mode);
    }

    /// `text` next to the 🤫 for `HINT_MS`, with the error ring unless a dictation is running.
    pub fn error(&mut self, text: &str, now: u64) {
        if self.state == State::Idle {
            self.show.mode(Mode::Error);
            self.error_until = Some(now + HINT_MS);
        }
        self.show.hint(text);
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
        fn transcript(&mut self, text: &str) -> Result<(), String> {
            self.0.borrow_mut().push(format!("history {text}"));
            self.1.clone()
        }
    }
    /// Pastes, or leaves the text on the clipboard with this hint.
    struct FakeInsert(Log, Option<&'static str>);
    impl Insert for FakeInsert {
        fn remember_focus(&mut self) {
            self.0.borrow_mut().push("remember focus".into());
        }
        fn insert(&mut self, text: &str) -> Result<Option<String>, String> {
            self.0.borrow_mut().push(format!("insert {text}"));
            Ok(self.1.map(String::from))
        }
    }
    struct FakeShow(Log);
    impl Show for FakeShow {
        fn mode(&mut self, mode: Mode) {
            self.0.borrow_mut().push(format!("mode {mode:?}"));
        }
        fn hint(&mut self, text: &str) {
            self.0.borrow_mut().push(format!("hint {text}"));
        }
    }

    type Fake = Flow<FakeMic, FakeStore, FakeInsert, FakeShow>;

    fn flow(mic: Result<(), String>, store: Result<(), String>, clipboard: Option<&'static str>) -> (Fake, Log) {
        let log = Log::default();
        let f = Flow::new(
            FakeMic(log.clone(), mic),
            FakeStore(log.clone(), store),
            FakeInsert(log.clone(), clipboard),
            FakeShow(log.clone()),
            rules,
        );
        (f, log)
    }

    fn take(log: &Log) -> Vec<String> {
        std::mem::take(&mut *log.borrow_mut())
    }

    fn key(key: Key, down: bool) -> KeyEvent {
        KeyEvent { key, down }
    }

    #[test]
    fn the_hotkey_is_ctrl_win_and_the_hint_names_it() {
        // Windows keyboards don't report fn, so the default is Ctrl+Win, as in Wispr's Windows
        // app. The hook's key and the hint's wording come from the same constant.
        assert_eq!(input::Hotkey::parse(HOTKEY), Ok(input::Hotkey::default()));
    }

    #[test]
    fn hook_events_drive_the_core_gesture() {
        // input reports the hotkey as one key; the core gesture wants Ctrl and Win. If the glue
        // drops either, Ctrl+Win never starts a dictation.
        let mut g = Gesture::default();
        assert_eq!(feed(&mut g, key(Key::Hotkey, true), 0), [Action::Start]);
        assert_eq!(feed(&mut g, key(Key::Hotkey, false), 600), [Action::Stop], "a 600 ms hold talks");

        assert_eq!(feed(&mut g, key(Key::Hotkey, true), 1000), [Action::Start]);
        assert_eq!(feed(&mut g, key(Key::Other(0x20), true), 1100), [Action::LockHandsFree], "Ctrl+Win+Space");
        assert_eq!(feed(&mut g, key(Key::Hotkey, false), 1200), []);
        assert_eq!(feed(&mut g, key(Key::Hotkey, true), 9000), [Action::Stop], "a tap ends hands-free");
        feed(&mut g, key(Key::Hotkey, false), 9050);

        assert_eq!(feed(&mut g, key(Key::Hotkey, true), 10_000), [Action::Start]);
        assert_eq!(feed(&mut g, key(Key::Other(0x44), true), 10_100), [Action::Cancel], "Ctrl+Win+D is a shortcut");
        feed(&mut g, key(Key::Hotkey, false), 10_200);

        assert_eq!(feed(&mut g, key(Key::Hotkey, true), 20_000), [Action::Start]);
        assert_eq!(feed(&mut g, key(Key::Esc, true), 21_500), [Action::Cancel]);
        assert_eq!(feed(&mut g, key(Key::Esc, false), 21_600), []);
    }

    #[test]
    fn hold_records_keeps_the_audio_then_pastes_into_the_window_that_kept_focus() {
        let (mut f, log) = flow(Ok(()), Ok(()), None);
        assert_eq!(f.action(Action::Start, 0), None);
        // Rule 8: the focused window is taken before the mic starts, not when the text is ready.
        assert_eq!(take(&log), ["remember focus", "mic start", "mode Recording"]);
        let samples = f.action(Action::Stop, 900).expect("a stop hands the samples to STT");
        assert_eq!(samples.len(), 16);
        // Rule 4: the clip is kept before it is transcribed, so a crash in STT still keeps it.
        assert_eq!(take(&log), ["mic stop", "keep 16 Dictation", "mode Processing"]);
        f.transcribed(Ok("  um hello world ".into()), 1100);
        assert_eq!(take(&log), ["history hello world", "insert hello world", "mode Idle"], "the core cleanup runs before insert");
    }

    // The date rule runs after the cleanup: before it, "the the" would leave a "the" in front of the date.
    #[test]
    fn spoken_dates_are_inserted_as_numbers() {
        let (mut f, log) = flow(Ok(()), Ok(()), None);
        f.action(Action::Start, 0);
        f.action(Action::Stop, 900);
        take(&log);
        f.transcribed(Ok("Um, see you on the the twenty sixth of July twenty twenty-six.".into()), 1100);
        assert_eq!(take(&log), ["history See you on 26.07.26.", "insert See you on 26.07.26.", "mode Idle"]);
    }

    #[test]
    fn focus_moved_leaves_the_text_on_the_clipboard_with_the_ctrl_v_hint() {
        let moved = "The window changed while you spoke. The text is on the clipboard: press Ctrl+V to paste it.";
        let (mut f, log) = flow(Ok(()), Ok(()), Some(moved));
        f.action(Action::Start, 0);
        f.action(Action::Stop, 900);
        take(&log);
        f.transcribed(Ok("hi".into()), 1000);
        assert_eq!(take(&log), ["history hi".to_string(), "insert hi".into(), "mode Idle".into(), format!("hint {moved}")]);
    }

    #[test]
    fn too_short_and_cancelled_are_kept_but_never_transcribed() {
        // Rules 2 and 4: nothing is transcribed or inserted, the audio is still kept and marked.
        let (mut f, log) = flow(Ok(()), Ok(()), None);
        f.action(Action::Start, 0);
        take(&log);
        assert_eq!(f.action(Action::TooShort, 600), None);
        let hint = "hint Hold Ctrl+Win to talk · double-tap for hands-free";
        assert_eq!(take(&log), ["mic stop", "keep 16 TooShort", "mode Idle", hint]);
        f.action(Action::Start, 5000);
        take(&log);
        assert_eq!(f.action(Action::Cancel, 5200), None);
        assert_eq!(take(&log), ["mic stop", "keep 16 Cancelled", "mode Idle"], "a cancel shows no hint");
    }

    #[test]
    fn hands_free_shows_its_own_state() {
        let (mut f, log) = flow(Ok(()), Ok(()), None);
        f.action(Action::Start, 0);
        f.action(Action::LockHandsFree, 300);
        assert_eq!(take(&log).last().unwrap(), "mode HandsFree");
        assert!(f.busy());
    }

    #[test]
    fn the_length_cap_warns_then_stops_and_transcribes() {
        let (mut f, log) = flow(Ok(()), Ok(()), None);
        let mut g = Gesture::default();
        let run = |f: &mut Fake, actions: Vec<Action>, t| actions.into_iter().filter_map(|a| f.action(a, t)).count();
        run(&mut f, g.hotkey_down(0), 0);
        run(&mut f, g.hotkey_up(100), 100);
        run(&mut f, g.hotkey_down(300), 300);
        take(&log);
        assert_eq!(run(&mut f, g.tick(19 * 60_000), 19 * 60_000), 0);
        assert_eq!(take(&log), ["hint Recording stops in 1 minute"], "the ring stays orange");
        assert_eq!(run(&mut f, g.tick(20 * 60_000), 20 * 60_000), 1, "the 20 minutes go to speech-to-text");
        assert_eq!(take(&log), ["mic stop", "keep 16 Dictation", "mode Processing"]);
        f.transcribed(Ok("a long one".into()), 20 * 60_000 + 500);
        assert_eq!(take(&log), ["history a long one", "insert a long one", "mode Idle"]);
        // A warning that arrives when nothing records shows nothing.
        f.action(Action::WarnDuration, 30 * 60_000);
        assert!(take(&log).is_empty());
    }

    #[test]
    fn a_press_while_transcribing_is_ignored() {
        let (mut f, log) = flow(Ok(()), Ok(()), None);
        f.action(Action::Start, 0);
        f.action(Action::Stop, 900);
        take(&log);
        assert_eq!(f.action(Action::Start, 950), None);
        assert_eq!(f.action(Action::Stop, 1500), None);
        assert!(take(&log).is_empty(), "the mic must not restart mid-transcription");
        f.transcribed(Ok("one".into()), 2000);
        f.transcribed(Ok("two".into()), 2100);
        assert_eq!(take(&log), ["history one", "insert one", "mode Idle"], "one transcript per stop");
        assert!(!f.busy());
    }

    #[test]
    fn mic_error_shows_for_2_s_and_clears() {
        let (mut f, log) = flow(Err("No microphone found".into()), Ok(()), None);
        f.action(Action::Start, 0);
        assert_eq!(take(&log), ["remember focus", "mic start", "mode Error", "hint No microphone found"]);
        assert_eq!(f.action(Action::Stop, 900), None, "nothing to stop");
        f.tick(HINT_MS - 1);
        assert!(take(&log).is_empty());
        f.tick(HINT_MS);
        assert_eq!(take(&log), ["mode Idle"]);
        f.tick(HINT_MS + 50);
        assert!(take(&log).is_empty(), "settled once");
    }

    #[test]
    fn a_new_dictation_is_not_cut_short_by_an_old_error() {
        let (mut f, log) = flow(Ok(()), Ok(()), None);
        f.action(Action::Start, 0);
        f.action(Action::Stop, 900);
        f.transcribed(Err("Model missing".into()), 1000);
        f.action(Action::Start, 1500);
        take(&log);
        f.tick(5000);
        assert!(take(&log).is_empty(), "the recording ring must stay");
    }

    #[test]
    fn an_outside_error_during_a_dictation_keeps_the_recording_ring() {
        // A meeting or start-at-login error must not make the user think the dictation failed.
        let (mut f, log) = flow(Ok(()), Ok(()), None);
        f.action(Action::Start, 0);
        take(&log);
        f.error("meeting probe failed", 100);
        f.tick(5000);
        assert_eq!(take(&log), ["hint meeting probe failed"]);
        assert!(f.action(Action::Stop, 6000).is_some(), "still recording");
    }

    #[test]
    fn a_failed_save_still_inserts_the_text_then_says_so() {
        let (mut f, log) = flow(Ok(()), Err("Disk full".into()), None);
        f.action(Action::Start, 0);
        f.action(Action::Stop, 900);
        take(&log);
        f.transcribed(Ok("keep me".into()), 1000);
        assert_eq!(take(&log), ["history keep me", "insert keep me", "mode Error", "hint Disk full"]);
    }

    #[test]
    fn empty_or_failed_transcript_inserts_nothing() {
        let (mut f, log) = flow(Ok(()), Ok(()), None);
        f.action(Action::Start, 0);
        f.action(Action::Stop, 900);
        take(&log);
        f.transcribed(Ok("   ".into()), 1000);
        assert_eq!(take(&log), ["mode Idle"]);
        f.action(Action::Start, 2000);
        f.action(Action::Stop, 2900);
        take(&log);
        f.transcribed(Err("Model missing".into()), 3000);
        assert_eq!(take(&log), ["mode Error", "hint Model missing"]);
    }
}
