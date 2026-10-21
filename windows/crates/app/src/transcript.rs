//! The Meeting transcript window that opens once a recorded meeting is transcribed: its text,
//! what its buttons do, and the transcript.md kept next to the audio. Pure, so it is tested on
//! any OS; `dialog.rs` draws the window and `win.rs` transcribes the meeting.

use std::path::{Path, PathBuf};

pub const TITLE: &str = "Meeting transcript";

/// The speaker of each channel and its file in the meeting folder (`meetings::Recording`).
pub const CHANNELS: [(&str, &str); 2] = [("Me", "Me.wav"), ("Others", "Others.wav")];

/// One speaker turn: when it starts (ms into the recording), who, and what was said.
#[derive(Debug, Clone, PartialEq)]
pub struct Turn {
    pub at_ms: u64,
    pub who: &'static str,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Meeting {
    pub dir: PathBuf,
    /// The meeting app, "" when unknown.
    pub app: String,
    pub seconds: u64,
    pub turns: Vec<Turn>,
    /// The channels that could not be transcribed, and why.
    pub notes: Vec<String>,
    /// Nothing makes a summary on Windows yet, so Copy summary stays off.
    pub summary: Option<String>,
}

impl Meeting {
    /// Transcribes each channel with `stt`: a file name in, its segments (start in ms, text) and
    /// its length in seconds out.
    pub fn transcribe(dir: PathBuf, app: String, mut stt: impl FnMut(&str) -> Result<(Vec<(u64, String)>, u64), String>) -> Meeting {
        let (mut channels, mut notes, mut seconds) = (vec![], vec![], 0);
        for (who, file) in CHANNELS {
            match stt(file) {
                Ok((segments, secs)) => {
                    seconds = seconds.max(secs);
                    channels.push((who, segments));
                }
                Err(e) => notes.push(format!("{who} was not transcribed: {e}")),
            }
        }
        Meeting { dir, app, seconds, turns: turns(&channels), notes, summary: None }
    }

    /// "Zoom · 21.10.26 14:05 · 42 min": the app when known, the start from the folder's name
    /// (`yyyyMMdd-HHmmss`, local time) and the length.
    pub fn header(&self) -> String {
        let started = self.dir.file_name().and_then(|n| started(&n.to_string_lossy()));
        let app = Some(self.app.clone()).filter(|a| !a.is_empty());
        app.into_iter().chain(started).chain([duration(self.seconds)]).collect::<Vec<_>>().join(" · ")
    }

    /// What Copy transcript puts on the clipboard and transcript.md holds: the header, then one
    /// `[hh:mm:ss] Speaker: text` paragraph per turn.
    pub fn transcript(&self) -> String {
        let mut out = self.header() + "\n";
        for n in &self.notes {
            out += &format!("\n{n}\n");
        }
        if self.turns.is_empty() && self.notes.is_empty() {
            out += "\nNo speech was recorded.\n";
        }
        for t in &self.turns {
            let s = t.at_ms / 1000;
            out += &format!("\n[{:02}:{:02}:{:02}] {}: {}\n", s / 3600, s / 60 % 60, s % 60, t.who, t.text);
        }
        out
    }

    /// The window's text: the summary on top (the transcript never waits for it), then the transcript.
    pub fn body(&self) -> String {
        let summary = match &self.summary {
            Some(s) => format!("Summary\n{s}"),
            None => "No summary: Shepetal for Windows does not summarize meetings yet.".into(),
        };
        let transcript = self.transcript();
        let (header, rest) = transcript.split_once('\n').unwrap_or((&transcript, ""));
        format!("{header}\n\n{summary}\n{rest}")
    }
}

/// The channels merged by start time (the first channel first at the same time), a speaker's
/// consecutive segments joined into one turn. Same rule as the Linux transcript.md.
pub fn turns(channels: &[(&'static str, Vec<(u64, String)>)]) -> Vec<Turn> {
    let mut segs: Vec<_> = channels.iter().flat_map(|(who, s)| s.iter().map(move |(t, x)| (*t, *who, x))).collect();
    segs.sort_by_key(|s| s.0); // stable, so the channel order breaks ties
    let mut out: Vec<Turn> = vec![];
    for (at_ms, who, text) in segs {
        match out.last_mut() {
            Some(last) if last.who == who => {
                last.text.push(' ');
                last.text.push_str(text);
            }
            _ => out.push(Turn { at_ms, who, text: text.clone() }),
        }
    }
    out
}

/// "20261021-140512" -> "21.10.26 14:05".
fn started(name: &str) -> Option<String> {
    let (d, t) = name.split_once('-')?;
    let ok = |s: &str, n| s.len() == n && s.bytes().all(|b| b.is_ascii_digit());
    (ok(d, 8) && ok(t, 6)).then(|| format!("{}.{}.{} {}:{}", &d[6..8], &d[4..6], &d[2..4], &t[0..2], &t[2..4]))
}

/// "< 1 min", "42 min", "1 h", "1 h 5 min", as on the Mac.
fn duration(seconds: u64) -> String {
    match (seconds / 3600, seconds / 60 % 60) {
        (0, 0) => "< 1 min".into(),
        (0, m) => format!("{m} min"),
        (h, 0) => format!("{h} h"),
        (h, m) => format!("{h} h {m} min"),
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Button {
    CopyTranscript,
    CopySummary,
    OpenFolder,
}

/// The real window and clipboard; tests use a fake.
pub trait Shell {
    /// Shows `text` in the one transcript window, in front but without taking the focus.
    /// `summary`: whether Copy summary is on.
    fn present(&mut self, text: &str, summary: bool);
    fn copy(&mut self, text: &str) -> Result<(), String>;
    fn open(&mut self, dir: &Path);
    /// The quiet note next to the buttons, "" for none.
    fn status(&mut self, text: &str);
}

/// One window for every meeting: a newer one replaces the text, so meetings never pile up.
pub struct Window<S> {
    pub shell: S,
    meeting: Option<Meeting>,
}

impl<S: Shell> Window<S> {
    pub fn new(shell: S) -> Self {
        Window { shell, meeting: None }
    }

    pub fn show(&mut self, m: Meeting) {
        self.shell.status("");
        self.shell.present(&m.body(), m.summary.is_some());
        self.meeting = Some(m);
    }

    /// The clipboard is written here only, on a click.
    pub fn click(&mut self, b: Button) {
        let Some(m) = &self.meeting else { return };
        let copied = match (b, &m.summary) {
            (Button::CopyTranscript, _) => self.shell.copy(&m.transcript()),
            (Button::CopySummary, Some(s)) => self.shell.copy(s),
            (Button::CopySummary, None) => return,
            (Button::OpenFolder, _) => return self.shell.open(&m.dir),
        };
        self.shell.status(&copied.map_or_else(|e| format!("Could not copy: {e}"), |()| "Copied".into()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn segs(v: &[(u64, &str)]) -> Vec<(u64, String)> {
        v.iter().map(|(t, x)| (*t, x.to_string())).collect()
    }

    fn zoom() -> Meeting {
        let dir = Path::new("meetings").join("20261021-140512");
        Meeting::transcribe(dir, "Zoom".into(), |file| match file {
            "Me.wav" => Ok((segs(&[(1_000, "Hello, can you hear me?"), (2_400, "Good."), (3_100, "I'll send the notes.")]), 2_530)),
            "Others.wav" => Ok((segs(&[(1_000, "Yes."), (5_900, "Thanks.")]), 2_531)),
            f => panic!("{f}"),
        })
    }

    const ZOOM: &str = "\
Zoom · 21.10.26 14:05 · 42 min

[00:00:01] Me: Hello, can you hear me?

[00:00:01] Others: Yes.

[00:00:02] Me: Good. I'll send the notes.

[00:00:05] Others: Thanks.
";

    /// Everything the window did, in order.
    #[derive(Default)]
    struct Fake {
        log: Vec<String>,
        clipboard: Option<String>,
        fail: bool,
    }

    impl Shell for Fake {
        fn present(&mut self, text: &str, summary: bool) {
            self.log.push(format!("present summary={summary} {}", text.lines().next().unwrap_or_default()));
        }
        fn copy(&mut self, text: &str) -> Result<(), String> {
            if self.fail {
                return Err("another app kept the clipboard open".into());
            }
            self.clipboard = Some(text.into());
            self.log.push("copy".into());
            Ok(())
        }
        fn open(&mut self, dir: &Path) {
            self.log.push(format!("open {}", dir.display()));
        }
        fn status(&mut self, text: &str) {
            self.log.push(format!("status {text}"));
        }
    }

    #[test]
    fn the_transcript_has_the_header_and_both_speakers_by_time() {
        // Me and Others interleave by time, and a speaker's back-to-back segments read as one turn.
        assert_eq!(zoom().transcript(), ZOOM);
    }

    #[test]
    fn the_window_shows_it_and_copies_only_on_a_click() {
        let mut w = Window::new(Fake::default());
        w.show(zoom());
        assert_eq!(w.shell.log, ["status ", "present summary=false Zoom · 21.10.26 14:05 · 42 min"]);
        assert_eq!(w.shell.clipboard, None, "showing the window never touches the clipboard");
        w.click(Button::CopyTranscript);
        assert_eq!(w.shell.clipboard.as_deref(), Some(ZOOM), "the whole transcript, with speakers and times");
        assert_eq!(w.shell.log[2..], ["copy", "status Copied"]);
    }

    #[test]
    fn copy_summary_stays_off_until_there_is_a_summary() {
        let mut w = Window::new(Fake::default());
        w.show(zoom());
        w.click(Button::CopySummary);
        assert_eq!(w.shell.clipboard, None);
        assert!(zoom().body().contains("does not summarize meetings yet"), "the window says why");

        let summary = Meeting { summary: Some("Notes go out today.".into()), ..zoom() };
        w.show(summary);
        assert!(w.shell.log.last().unwrap().starts_with("present summary=true"));
        w.click(Button::CopySummary);
        assert_eq!(w.shell.clipboard.as_deref(), Some("Notes go out today."));
    }

    #[test]
    fn the_summary_sits_on_top_of_the_transcript() {
        let m = Meeting { summary: Some("Notes go out today.".into()), ..zoom() };
        let body = m.body();
        let (head, transcript) = body.split_once("\n\nSummary\nNotes go out today.\n").expect(&body);
        assert_eq!(head, "Zoom · 21.10.26 14:05 · 42 min");
        assert!(transcript.starts_with("\n[00:00:01] Me: Hello"), "{body}");
    }

    #[test]
    fn a_newer_meeting_replaces_the_text_of_the_one_window() {
        let mut w = Window::new(Fake::default());
        w.show(zoom());
        let teams = Meeting { app: "Microsoft Teams".into(), turns: vec![], ..zoom() };
        w.show(teams);
        w.click(Button::CopyTranscript);
        assert!(w.shell.clipboard.as_deref().unwrap().starts_with("Microsoft Teams ·"), "the latest meeting is copied");
    }

    #[test]
    fn no_speech_says_so_and_still_opens_the_folder() {
        let dir = Path::new("meetings").join("20261021-090000");
        let m = Meeting::transcribe(dir.clone(), "Zoom".into(), |_| Ok((vec![], 20)));
        assert_eq!(m.transcript(), "Zoom · 21.10.26 09:00 · < 1 min\n\nNo speech was recorded.\n");
        let mut w = Window::new(Fake::default());
        w.show(m);
        w.click(Button::OpenFolder);
        assert_eq!(w.shell.log.last().unwrap(), &format!("open {}", dir.display()));
        assert_eq!(w.shell.clipboard, None);
    }

    #[test]
    fn a_channel_that_failed_is_named_not_left_out() {
        let m = Meeting::transcribe(PathBuf::from("20261021-140512"), "Zoom".into(), |file| match file {
            "Me.wav" => Err("Could not load the speech model. Delete it to download it again.".into()),
            _ => Ok((segs(&[(5_000, "Thanks.")]), 65)),
        });
        assert_eq!(
            m.transcript(),
            "Zoom · 21.10.26 14:05 · 1 min\n\nMe was not transcribed: Could not load the speech model. Delete it to download it again.\n\n[00:00:05] Others: Thanks.\n"
        );
        let none = Meeting { turns: vec![], ..m };
        assert!(!none.transcript().contains("No speech"), "a failed channel is not silence");
    }

    #[test]
    fn a_failed_copy_says_so_quietly() {
        let mut w = Window::new(Fake { fail: true, ..Fake::default() });
        w.click(Button::CopyTranscript);
        assert!(w.shell.log.is_empty(), "nothing to copy before a meeting");
        w.show(zoom());
        w.click(Button::CopyTranscript);
        assert_eq!(w.shell.log.last().unwrap(), "status Could not copy: another app kept the clipboard open");
    }

    #[test]
    fn the_window_never_takes_the_focus_on_its_own() {
        // Rule 8: it opens in front of the call but leaves the keyboard there; only a click on it
        // activates it. dialog.rs draws it and no test can run its Win32 calls, so read them.
        let src = include_str!("dialog.rs");
        let win = &src[src.find("pub struct Transcripts").unwrap()..];
        assert!(win.contains("ShowWindow(self.hwnd, SW_SHOWNOACTIVATE)"));
        for api in ["SetForegroundWindow", "SetActiveWindow", "SetFocus", "BringWindowToTop", "SW_SHOWNORMAL", "SW_SHOW)", "SW_RESTORE"] {
            assert!(!win.contains(api), "the transcript window calls {api}");
        }
        assert!(win.contains("let keep = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;"));
        assert_eq!(win.matches("SetWindowPos(").count(), win.matches(", keep);").count(), "every raise is without activating");
        assert_eq!(win.matches("insert::copy").count(), 1, "the clipboard is written in Shell::copy only");
    }

    #[test]
    fn header_dates_are_dd_mm_yy_and_the_app_is_left_out_when_unknown() {
        let m = |app: &str, dir: &str, seconds| Meeting { app: app.into(), dir: dir.into(), seconds, ..zoom() }.header();
        assert_eq!(m("", "20260305-080910", 59), "05.03.26 08:09 · < 1 min");
        assert_eq!(m("Google Meet (Chrome)", "20261231-235959", 3600), "Google Meet (Chrome) · 31.12.26 23:59 · 1 h");
        assert_eq!(m("Zoom", "20261021-140512", 3900), "Zoom · 21.10.26 14:05 · 1 h 5 min");
        assert_eq!(m("Zoom", "not-a-stamp", 120), "Zoom · 2 min", "no date rather than a wrong one");
    }
}
