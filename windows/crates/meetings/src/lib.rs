//! Meeting detection and recording for shepetal on Windows.
//!
//! [`Detector`] is a pure state machine over [`Snapshot`]s (which processes hold the mic, which
//! windows are open), ported from the Mac `MeetingCore` detector with the docs/re/meetings.md
//! thresholds as [`Config`]. It also decides when to offer "Record?" and when the recording
//! starts (only after the user accepts) and stops, so all of that is tested on any OS. The Win32 probe and the WASAPI capture are in `win` (Windows only).

use std::collections::{BTreeMap, BTreeSet};

mod wav;
#[cfg(windows)]
mod win;
#[cfg(windows)]
pub use win::{snapshot, watch, Notice, Recording};

/// A process with an active audio session on a capture device (it is using the mic).
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct MicClient {
    /// Executable file name, e.g. `zoom.exe`. Matched case-insensitively.
    pub exe: String,
    pub pid: u32,
}

/// A visible top-level window.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Window {
    pub exe: String,
    pub title: String,
}

/// One observation of the system, taken about once a second.
#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub mic: Vec<MicClient>,
    /// Visible titled windows (Slack's huddle window need not be in front).
    pub windows: Vec<Window>,
    /// The window in focus. A browser counts only when this is its meeting tab.
    pub foreground: Option<Window>,
    /// Default capture and render device IDs. A change starts the device-change grace.
    pub devices: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Started(String),
    Ended(String),
    /// The first meeting started: show the one-click "Record?" offer. Nothing records until
    /// the user clicks it ([`Detector::accept`]).
    OfferRecording,
    /// The last meeting ended before the offer was clicked: hide it.
    WithdrawOffer,
    /// The user accepted the offer: record Me.wav and Others.wav.
    StartRecording,
    /// The last meeting of a recording ended: close the files.
    StopRecording,
}

/// Thresholds in seconds, defaults from docs/re/meetings.md.
#[derive(Debug, Clone)]
pub struct Config {
    /// A meeting app must hold the mic this long before a meeting starts.
    pub start_after: f64,
    /// No end in the first seconds of a meeting.
    pub min_session: f64,
    /// Wait after the mic is released when nothing proves the meeting still runs (a native app
    /// let go, or the browser tab / huddle window is gone too)...
    pub end_with_evidence: f64,
    /// ...and when that proof is still there.
    pub end_without_evidence: f64,
    /// The mic coming back within this window is the same meeting.
    pub reacquire: f64,
    /// A default-device change suppresses ends for this long.
    pub device_change_grace: f64,
    /// shepetal's own process: its mic use (dictation, this recorder) never counts.
    pub self_pid: u32,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            start_after: 5.0,
            min_session: 15.0,
            end_with_evidence: 3.0,
            end_without_evidence: 30.0,
            reacquire: 4.0,
            device_change_grace: 10.0,
            self_pid: std::process::id(),
        }
    }
}

/// Native apps that only hold the mic during a call: trusted alone.
const NATIVE: &[(&str, &str)] = &[
    ("zoom.exe", "Zoom"),
    ("ms-teams.exe", "Microsoft Teams"),
    ("teams.exe", "Microsoft Teams"),
    ("webex.exe", "Webex"),
    ("ciscocollabhost.exe", "Webex"),
    ("atmgr.exe", "Webex"),
    ("discord.exe", "Discord"),
];

/// Browsers count only while their focused tab is a web meeting.
const BROWSERS: &[(&str, &str)] = &[
    ("chrome.exe", "Chrome"),
    ("msedge.exe", "Edge"),
    ("firefox.exe", "Firefox"),
    ("brave.exe", "Brave"),
    ("arc.exe", "Arc"),
];

/// Web meetings recognised by the browser window title (= its active tab's title).
const WEB_TITLES: &[(&str, &str)] = &[
    ("Meet - ", "Google Meet"),
    ("Meet – ", "Google Meet"),
    ("Google Meet", "Google Meet"),
    ("meet.google.com", "Google Meet"),
    ("Microsoft Teams", "Microsoft Teams"),
    ("Zoom Meeting", "Zoom"),
    ("app.zoom.us", "Zoom"),
];

/// Turns snapshots into debounced meeting and recording events. The caller supplies the clock.
pub struct Detector {
    pub cfg: Config,
    pending_since: BTreeMap<String, f64>,
    lost_since: BTreeMap<String, f64>,
    started_at: BTreeMap<String, f64>,
    /// Mic holders seen for each active meeting.
    holders: BTreeMap<String, BTreeSet<MicClient>>,
    device_grace_until: f64,
    last_devices: Option<Vec<String>>,
    active: BTreeSet<String>,
    /// The user accepted "Record?" for the current run of meetings.
    recording: bool,
}

impl Detector {
    pub fn new(cfg: Config) -> Self {
        Detector {
            cfg,
            pending_since: BTreeMap::new(),
            lost_since: BTreeMap::new(),
            started_at: BTreeMap::new(),
            holders: BTreeMap::new(),
            device_grace_until: f64::NEG_INFINITY,
            last_devices: None,
            active: BTreeSet::new(),
            recording: false,
        }
    }

    /// Meetings running now, e.g. "Zoom" or "Google Meet (Chrome)".
    pub fn active(&self) -> &BTreeSet<String> {
        &self.active
    }

    /// The meeting apps visible in one snapshot, ignoring debounce.
    pub fn meeting_apps(&self, s: &Snapshot) -> BTreeSet<String> {
        self.matches(s).into_keys().collect()
    }

    /// Meeting apps in one snapshot with the mic clients that make each one.
    fn matches(&self, s: &Snapshot) -> BTreeMap<String, BTreeSet<MicClient>> {
        let mut apps: BTreeMap<String, BTreeSet<MicClient>> = BTreeMap::new();
        for c in s.mic.iter().filter(|c| c.pid != self.cfg.self_pid) {
            let exe = c.exe.to_lowercase();
            let app = if let Some((_, name)) = NATIVE.iter().find(|(e, _)| *e == exe) {
                Some(name.to_string())
            } else if exe == "slack.exe" {
                // Slack holds the mic for clips too: only a huddle window counts.
                let huddle = s.windows.iter().chain(&s.foreground).any(|w| {
                    w.exe.eq_ignore_ascii_case("slack.exe")
                        && w.title.to_lowercase().contains("huddle")
                });
                huddle.then(|| "Slack".to_string())
            } else if let Some((_, browser)) = BROWSERS.iter().find(|(e, _)| *e == exe) {
                s.foreground
                    .as_ref()
                    .filter(|w| w.exe.eq_ignore_ascii_case(&exe))
                    .and_then(|w| {
                        WEB_TITLES
                            .iter()
                            .find(|(needle, _)| w.title.contains(needle))
                    })
                    .map(|(_, web)| format!("{web} ({browser})"))
            } else {
                None
            };
            if let Some(app) = app {
                apps.entry(app).or_default().insert(c.clone());
            }
        }
        apps
    }

    /// A released meeting ends on the short wait when nothing still proves it: a native app's
    /// release is trusted, a browser or Slack meeting once its tab or huddle window is gone too.
    fn is_bound(&self, app: &str, s: &Snapshot) -> bool {
        if NATIVE.iter().any(|(_, name)| *name == app) {
            return true;
        }
        let proof = Snapshot {
            mic: self
                .holders
                .get(app)
                .into_iter()
                .flatten()
                .cloned()
                .collect(),
            ..s.clone()
        };
        !self.matches(&proof).contains_key(app)
    }

    pub fn update(&mut self, s: &Snapshot, now: f64) -> Vec<Event> {
        if self.last_devices.as_ref().is_some_and(|d| *d != s.devices) {
            self.device_grace_until = now + self.cfg.device_change_grace;
        }
        self.last_devices = Some(s.devices.clone());

        let was_idle = self.active.is_empty();
        let found = self.matches(s);
        let mut events = vec![];
        for (app, clients) in &found {
            if !self.active.contains(app) {
                let since = *self.pending_since.entry(app.clone()).or_insert(now);
                if now - since < self.cfg.start_after {
                    continue;
                }
                self.pending_since.remove(app);
                self.started_at.insert(app.clone(), now);
                self.active.insert(app.clone());
                events.push(Event::Started(app.clone()));
            }
            self.holders
                .entry(app.clone())
                .or_default()
                .extend(clients.iter().cloned());
        }
        // A candidate that drops out before start_after starts over (flapping).
        self.pending_since.retain(|app, _| found.contains_key(app));

        for app in self.active.clone() {
            // A running call stays on while its holder keeps the mic, even when its tab is not
            // in front any more.
            let held = self
                .holders
                .get(&app)
                .is_some_and(|h| s.mic.iter().any(|c| h.contains(c)));
            if found.contains_key(&app) || held {
                self.lost_since.remove(&app);
                continue;
            }
            let since = *self.lost_since.entry(app.clone()).or_insert(now);
            let wait = if self.is_bound(&app, s) {
                self.cfg.end_with_evidence
            } else {
                self.cfg.end_without_evidence
            };
            if now - since >= wait.max(self.cfg.reacquire)
                && now - self.started_at[&app] >= self.cfg.min_session
                && now >= self.device_grace_until
            {
                self.lost_since.remove(&app);
                self.started_at.remove(&app);
                self.holders.remove(&app);
                self.active.remove(&app);
                events.push(Event::Ended(app));
            }
        }

        // One offer, and one recording, covers overlapping meetings: it captures the whole mic
        // and system mix.
        if was_idle && !self.active.is_empty() {
            events.push(Event::OfferRecording);
        }
        if !was_idle && self.active.is_empty() {
            events.push(if self.recording {
                Event::StopRecording
            } else {
                Event::WithdrawOffer
            });
            self.recording = false;
        }
        events
    }

    /// The user clicked "Record?": starts the recording while the offer stands. A click after
    /// the meetings ended, or a second click, does nothing.
    pub fn accept(&mut self) -> Vec<Event> {
        if self.active.is_empty() || self.recording {
            return vec![];
        }
        self.recording = true;
        vec![Event::StartRecording]
    }
}

/// Frames of silence to insert before a packet captured `elapsed_100ns` after the recording
/// started, when `written` frames are on disk. WASAPI loopback delivers nothing while no app
/// plays sound, so without this Others.wav would lose its silences and drift ahead of Me.wav.
/// Lag under 100 ms is left alone.
#[cfg_attr(not(windows), allow(dead_code))]
fn gap_frames(written: u64, elapsed_100ns: u64) -> u64 {
    let rate = wav::RATE as u64;
    let expected = elapsed_100ns * rate / 10_000_000;
    if expected > written + rate / 10 {
        expected - written
    } else {
        0
    }
}

/// DACL for a meeting dir: "P" (protected) inherits nothing from %LOCALAPPDATA%, so no
/// Administrators or SYSTEM entries; the one ACE gives the user full access and OICI hands it
/// down to Me.wav and Others.wav.
#[cfg_attr(not(windows), allow(dead_code))]
fn owner_only_sddl(user_sid: &str) -> String {
    format!("D:P(A;OICI;FA;;;{user_sid})")
}

#[cfg(test)]
mod tests {
    use super::*;

    const SELF: u32 = 4000;

    fn mic(exe: &str, pid: u32) -> MicClient {
        MicClient {
            exe: exe.into(),
            pid,
        }
    }
    fn win(exe: &str, title: &str) -> Window {
        Window {
            exe: exe.into(),
            title: title.into(),
        }
    }
    fn zoom() -> MicClient {
        mic("Zoom.exe", 10)
    }
    fn teams() -> MicClient {
        mic("ms-teams.exe", 20)
    }
    fn chrome() -> MicClient {
        mic("chrome.exe", 30)
    }
    fn holding(clients: &[MicClient]) -> Snapshot {
        Snapshot {
            mic: clients.to_vec(),
            ..Default::default()
        }
    }
    fn meet_tab() -> Window {
        win("chrome.exe", "Meet - abc-defg-hij - Google Chrome")
    }
    /// Chrome holds the mic and its Meet tab is the focused window.
    fn meet_call() -> Snapshot {
        Snapshot {
            mic: vec![chrome()],
            foreground: Some(meet_tab()),
            ..Default::default()
        }
    }
    fn released() -> Snapshot {
        Snapshot::default()
    }
    fn detector() -> Detector {
        Detector::new(Config {
            self_pid: SELF,
            ..Default::default()
        })
    }
    fn started(app: &str) -> Event {
        Event::Started(app.into())
    }
    fn ended(app: &str) -> Event {
        Event::Ended(app.into())
    }
    /// Feeds the same snapshot once per second over [from, to] and collects the events.
    fn run(d: &mut Detector, s: &Snapshot, from: u32, to: u32) -> Vec<Event> {
        (from..=to).flat_map(|t| d.update(s, t as f64)).collect()
    }

    #[test]
    fn starts_and_offers_to_record_after_five_second_grace() {
        let mut d = detector();
        let s = holding(&[zoom()]);
        assert_eq!(run(&mut d, &s, 0, 4), vec![]);
        assert_eq!(
            d.update(&s, 5.0),
            vec![started("Zoom"), Event::OfferRecording]
        );
        assert_eq!(
            run(&mut d, &s, 6, 20),
            vec![],
            "no second start or offer while the call runs"
        );
    }

    #[test]
    fn records_only_after_the_record_click() {
        // Pavel's rule: a detected meeting is never recorded on its own, only after one click
        // on "Record?".
        let mut d = detector();
        let call = holding(&[zoom()]);
        let events = run(&mut d, &call, 0, 60);
        assert!(!events.contains(&Event::StartRecording), "{events:?}");
        assert_eq!(d.accept(), vec![Event::StartRecording]);
        assert_eq!(d.accept(), vec![], "a second click starts nothing");
        assert_eq!(run(&mut d, &call, 61, 90), vec![]);
        assert_eq!(
            run(&mut d, &released(), 91, 95),
            vec![ended("Zoom"), Event::StopRecording]
        );
        // The next meeting asks again, and its click records again.
        assert_eq!(
            run(&mut d, &call, 100, 105),
            vec![started("Zoom"), Event::OfferRecording]
        );
        assert_eq!(d.accept(), vec![Event::StartRecording]);
    }

    #[test]
    fn an_unanswered_offer_records_nothing() {
        let mut d = detector();
        assert_eq!(d.accept(), vec![], "no meeting, nothing to accept");
        run(&mut d, &holding(&[zoom()]), 0, 30);
        assert_eq!(
            run(&mut d, &released(), 31, 35),
            vec![ended("Zoom"), Event::WithdrawOffer],
            "the offer goes away, there is no recording to stop"
        );
        assert_eq!(
            d.accept(),
            vec![],
            "a late click after the meeting starts nothing"
        );
        // The next meeting asks again.
        assert_eq!(
            run(&mut d, &holding(&[zoom()]), 40, 45),
            vec![started("Zoom"), Event::OfferRecording]
        );
    }

    #[test]
    fn native_release_ends_after_reacquire_window() {
        // A native app letting go of the mic is trusted (bound): 3 s, clamped to the 4 s
        // reacquire window, not the 30 s unbound wait.
        let mut d = detector();
        run(&mut d, &holding(&[zoom()]), 0, 30);
        assert_eq!(run(&mut d, &released(), 31, 34), vec![]);
        assert_eq!(
            d.update(&released(), 35.0),
            vec![ended("Zoom"), Event::WithdrawOffer]
        );
    }

    #[test]
    fn mic_back_within_four_seconds_is_the_same_meeting() {
        let mut d = detector();
        run(&mut d, &holding(&[zoom()]), 0, 30);
        let mut events = run(&mut d, &released(), 31, 33);
        events.extend(run(&mut d, &holding(&[zoom()]), 34, 49));
        assert_eq!(events, vec![], "no end, no new start, no new recording");
        // The next real release gets the full wait again, not the stale time from 31 s.
        assert_eq!(run(&mut d, &released(), 50, 53), vec![]);
        assert_eq!(
            d.update(&released(), 54.0),
            vec![ended("Zoom"), Event::WithdrawOffer]
        );
    }

    #[test]
    fn no_end_in_first_fifteen_seconds() {
        let mut d = detector();
        assert_eq!(
            run(&mut d, &holding(&[zoom()]), 0, 5),
            vec![started("Zoom"), Event::OfferRecording]
        );
        assert_eq!(
            run(&mut d, &released(), 6, 19),
            vec![],
            "session only 14 s old"
        );
        assert_eq!(
            d.update(&released(), 20.0),
            vec![ended("Zoom"), Event::WithdrawOffer]
        );
    }

    #[test]
    fn browser_drop_with_tab_still_open_waits_thirty_seconds() {
        // Chrome let go of the mic but the Meet tab is still in front (unbound): 30 s.
        let mut d = detector();
        run(&mut d, &meet_call(), 0, 30);
        let tab_open = Snapshot {
            foreground: Some(meet_tab()),
            ..Default::default()
        };
        assert_eq!(run(&mut d, &tab_open, 31, 60), vec![]);
        assert_eq!(
            d.update(&tab_open, 61.0),
            vec![ended("Google Meet (Chrome)"), Event::WithdrawOffer]
        );

        // Tab gone too (bound): the short wait.
        let mut d = detector();
        run(&mut d, &meet_call(), 0, 30);
        assert_eq!(run(&mut d, &released(), 31, 34), vec![]);
        assert_eq!(
            d.update(&released(), 35.0),
            vec![ended("Google Meet (Chrome)"), Event::WithdrawOffer]
        );
    }

    #[test]
    fn flapping_mic_does_not_start() {
        // The mic toggles every 2 s: never held 5 s in a row.
        let mut d = detector();
        let (on, off) = (holding(&[zoom()]), released());
        let events: Vec<_> = (0..40)
            .flat_map(|t| d.update(if t % 4 < 2 { &on } else { &off }, t as f64))
            .collect();
        assert_eq!(events, vec![]);
    }

    #[test]
    fn device_change_is_not_an_end() {
        // Plugging in a headset changes the default devices and can drop the mic for a moment.
        let mut d = detector();
        let call = Snapshot {
            mic: vec![zoom()],
            devices: vec!["mic".into(), "speakers".into()],
            ..Default::default()
        };
        run(&mut d, &call, 0, 30);
        let headset = Snapshot {
            devices: vec!["headset".into(), "headset".into()],
            ..Default::default()
        };
        assert_eq!(
            run(&mut d, &headset, 31, 40),
            vec![],
            "would end at 35 without the change"
        );
        assert_eq!(
            d.update(&headset, 41.0),
            vec![ended("Zoom"), Event::WithdrawOffer]
        );
    }

    #[test]
    fn two_apps_at_once_share_one_recording() {
        let mut d = detector();
        assert_eq!(
            run(&mut d, &holding(&[zoom()]), 0, 5),
            vec![started("Zoom"), Event::OfferRecording]
        );
        assert_eq!(d.accept(), vec![Event::StartRecording]);
        assert_eq!(
            run(&mut d, &holding(&[zoom(), teams()]), 6, 30),
            vec![started("Microsoft Teams")],
            "no second offer, no second recording"
        );
        assert_eq!(
            run(&mut d, &holding(&[teams()]), 31, 35),
            vec![ended("Zoom")],
            "Teams still records"
        );
        assert_eq!(d.active().iter().collect::<Vec<_>>(), ["Microsoft Teams"]);
        assert_eq!(
            run(&mut d, &released(), 36, 40),
            vec![ended("Microsoft Teams"), Event::StopRecording]
        );
    }

    #[test]
    fn end_evidence_is_per_app() {
        // Zoom's release ends Zoom fast, while the Meet tab still in front keeps Meet on the 30 s wait.
        let mut d = detector();
        let both = Snapshot {
            mic: vec![zoom(), chrome()],
            foreground: Some(meet_tab()),
            ..Default::default()
        };
        assert_eq!(
            run(&mut d, &both, 0, 30),
            vec![
                started("Google Meet (Chrome)"),
                started("Zoom"),
                Event::OfferRecording
            ]
        );
        let tab_open = Snapshot {
            foreground: Some(meet_tab()),
            ..Default::default()
        };
        assert_eq!(run(&mut d, &tab_open, 31, 35), vec![ended("Zoom")]);
        assert_eq!(
            run(&mut d, &tab_open, 36, 61),
            vec![ended("Google Meet (Chrome)"), Event::WithdrawOffer]
        );
    }

    #[test]
    fn browser_counts_only_with_a_meeting_title_in_front() {
        let apps = |s: Snapshot| detector().meeting_apps(&s).into_iter().collect::<Vec<_>>();
        let browser = |m: MicClient, front: Window| Snapshot {
            mic: vec![m],
            foreground: Some(front),
            ..Default::default()
        };

        assert_eq!(apps(meet_call()), ["Google Meet (Chrome)"]);
        assert_eq!(
            apps(browser(
                mic("msedge.exe", 31),
                win(
                    "msedge.exe",
                    "Weekly sync | Microsoft Teams - Microsoft Edge"
                )
            )),
            ["Microsoft Teams (Edge)"]
        );
        assert_eq!(
            apps(browser(
                mic("firefox.exe", 32),
                win("firefox.exe", "Zoom Meeting — Mozilla Firefox")
            )),
            ["Zoom (Firefox)"]
        );
        // A browser on the mic with any other page in front is not a meeting.
        assert_eq!(
            apps(browser(
                chrome(),
                win("chrome.exe", "Inbox - Gmail - Google Chrome")
            )),
            [] as [&str; 0]
        );
        // The Meet tab exists but another app is in focus.
        let behind = Snapshot {
            mic: vec![chrome()],
            windows: vec![meet_tab()],
            foreground: Some(win("notepad.exe", "notes")),
            ..Default::default()
        };
        assert_eq!(apps(behind), [] as [&str; 0]);
        // Edge holds the mic, but the Meet title in front belongs to Chrome.
        assert_eq!(
            apps(browser(mic("msedge.exe", 31), meet_tab())),
            [] as [&str; 0]
        );
    }

    #[test]
    fn switching_away_from_the_meet_tab_does_not_end_it() {
        // Only the focused window is read. While Chrome keeps the mic the call goes on.
        let mut d = detector();
        assert_eq!(
            run(&mut d, &meet_call(), 0, 30),
            vec![started("Google Meet (Chrome)"), Event::OfferRecording]
        );
        let docs = Snapshot {
            mic: vec![chrome()],
            foreground: Some(win("winword.exe", "Q3 plan - Word")),
            ..Default::default()
        };
        assert_eq!(run(&mut d, &docs, 31, 70), vec![]);
        assert_eq!(
            d.active().iter().collect::<Vec<_>>(),
            ["Google Meet (Chrome)"]
        );
    }

    #[test]
    fn slack_needs_a_huddle_window() {
        let mut d = detector();
        let slack = mic("slack.exe", 40);
        assert_eq!(
            run(&mut d, &holding(std::slice::from_ref(&slack)), 0, 30),
            vec![],
            "e.g. recording a clip"
        );
        let channel = Snapshot {
            mic: vec![slack.clone()],
            windows: vec![win("slack.exe", "general (Channel) - Acme - Slack")],
            ..Default::default()
        };
        assert_eq!(run(&mut d, &channel, 31, 60), vec![]);
        // The huddle window does not need focus.
        let huddle = Snapshot {
            mic: vec![slack],
            windows: vec![win("slack.exe", "Huddle: #general - Acme - Slack")],
            foreground: Some(win("notepad.exe", "notes")),
            ..Default::default()
        };
        assert_eq!(
            run(&mut d, &huddle, 61, 66),
            vec![started("Slack"), Event::OfferRecording]
        );
    }

    #[test]
    fn shepetal_own_mic_use_never_counts() {
        // Our own dictation or recorder stream, whatever the binary is called.
        let mut d = detector();
        assert_eq!(
            run(&mut d, &holding(&[mic("zoom.exe", SELF)]), 0, 60),
            vec![]
        );
        assert_eq!(
            run(&mut d, &holding(&[mic("zoom.exe", SELF), zoom()]), 61, 66),
            vec![started("Zoom"), Event::OfferRecording]
        );
    }

    #[test]
    fn native_apps_match_exe_names_case_insensitively() {
        let d = detector();
        let app = |exe: &str| {
            d.meeting_apps(&holding(&[mic(exe, 50)]))
                .into_iter()
                .collect::<Vec<_>>()
        };
        assert_eq!(app("ZOOM.EXE"), ["Zoom"]);
        assert_eq!(app("Teams.exe"), ["Microsoft Teams"]);
        assert_eq!(app("ms-teams.exe"), ["Microsoft Teams"]);
        assert_eq!(app("CiscoCollabHost.exe"), ["Webex"]);
        assert_eq!(app("Discord.exe"), ["Discord"]);
        assert_eq!(app("spotify.exe"), [] as [&str; 0]);
    }

    #[test]
    fn silent_loopback_is_padded_to_the_timeline() {
        // 2 s into the recording with nothing written (no app played sound): 2 s of silence.
        assert_eq!(gap_frames(0, 20_000_000), 32_000);
        // A packet 50 ms late is normal jitter: nothing inserted.
        assert_eq!(gap_frames(16_000, 10_500_000), 0);
        // Already ahead of the clock: nothing inserted.
        assert_eq!(gap_frames(20_000, 10_000_000), 0);
    }

    #[test]
    fn meeting_dir_grants_only_the_user() {
        assert_eq!(
            owner_only_sddl("S-1-5-21-1-2-3-1001"),
            "D:P(A;OICI;FA;;;S-1-5-21-1-2-3-1001)"
        );
    }
}
