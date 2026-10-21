//! Meeting detection and recording for shepetal on Windows.
//!
//! A possible meeting is any other app using the mic or the camera (Pavel, 2026-10-21): no app
//! lists and no window titles. [`in_use`] reads who uses them from the CapabilityAccessManager
//! ConsentStore, the records behind Windows' own mic and camera indicators, so detection needs no
//! permission. [`Detector`] is a pure state machine over those [`Snapshot`]s. It also decides when
//! to offer "Record?" and when the recording starts (only after the user accepts) and stops, so
//! all of that is tested on any OS. The registry reads and the WASAPI capture are in `win`
//! (Windows only).

use std::io;
use std::path::Path;

mod wav;
#[cfg(windows)]
mod win;
#[cfg(windows)]
pub use win::{snapshot, watch, Notice, Recording};

/// One observation of the system, taken about once a second.
#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    /// Other apps using the mic or the camera now, by name ([`in_use`]).
    pub apps: Vec<String>,
    /// Default capture and render device IDs. A change starts the device-change grace.
    pub devices: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Another app has used the mic or the camera for `start_after`: show the one-click
    /// "Record?" naming that app. Nothing records until the user clicks it ([`Detector::accept`]).
    OfferRecording(String),
    /// Hide the offer: nobody answered it in `offer_for`, or the mic and camera were released.
    WithdrawOffer,
    /// The user accepted the offer: record Me.wav and Others.wav.
    StartRecording,
    /// The meeting of a recording ended: close the files.
    StopRecording,
}

/// Thresholds in seconds.
#[derive(Debug, Clone)]
pub struct Config {
    /// Another app must use the mic or the camera this long before the offer.
    pub start_after: f64,
    /// No end in the first seconds of a meeting.
    pub min_session: f64,
    /// The meeting ends once no other app has used the mic or the camera this long.
    pub end_after: f64,
    /// A default-device change suppresses ends for this long.
    pub device_change_grace: f64,
    /// An unanswered offer goes away after this long.
    pub offer_for: f64,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            start_after: 5.0,
            min_session: 15.0,
            end_after: 4.0,
            device_change_grace: 10.0,
            offer_for: 20.0,
        }
    }
}

/// The part of HKCU's CapabilityAccessManager ConsentStore that [`in_use`] reads, by key path
/// relative to the ConsentStore. `win` reads the real one; the tests use fixtures.
pub trait Registry {
    /// The names of the subkeys of `path`, none when the key does not exist.
    fn subkeys(&self, path: &str) -> io::Result<Vec<String>>;
    /// A REG_QWORD value, None when it is missing.
    fn qword(&self, path: &str, name: &str) -> Option<u64>;
}

/// The apps using the mic or the camera now, by name, shepetal itself (`own_exe`) left out.
/// Windows keeps a key per app under `microphone` and `webcam`: a packaged app's is its package
/// family name, and a desktop app's, under `NonPackaged`, is its exe path with `#` for `\`.
/// LastUsedTimeStop is 0 while the app uses the device, after a LastUsedTimeStart.
pub fn in_use(reg: &impl Registry, own_exe: &Path) -> io::Result<Vec<String>> {
    let using = |key: &str| {
        reg.qword(key, "LastUsedTimeStop") == Some(0)
            && reg.qword(key, "LastUsedTimeStart").is_some_and(|t| t > 0)
    };
    let own = own_exe.to_string_lossy();
    let mut apps = vec![];
    for device in ["microphone", "webcam"] {
        for key in reg.subkeys(device)? {
            if key != "NonPackaged" {
                // e.g. MSTeams_8wekyb3d8bbwe or Microsoft.WindowsCamera_8wekyb3d8bbwe
                if using(&format!(r"{device}\{key}")) {
                    let family = key.split('_').next().unwrap_or_default();
                    apps.push(family.rsplit('.').next().unwrap_or_default().to_string());
                }
                continue;
            }
            for exe in reg.subkeys(&format!(r"{device}\NonPackaged"))? {
                let path = exe.replace('#', r"\");
                // The exact path, never the name: shepetal keeps its mic open the whole time it
                // runs (the dictation pre-roll), and records meetings itself.
                if path.eq_ignore_ascii_case(&own)
                    || !using(&format!(r"{device}\NonPackaged\{exe}"))
                {
                    continue;
                }
                let file = path.rsplit('\\').next().unwrap_or_default();
                let exe = file.to_ascii_lowercase().ends_with(".exe");
                apps.push(file[..file.len() - if exe { 4 } else { 0 }].to_string());
            }
        }
    }
    Ok(apps)
}

/// Turns snapshots into debounced offer and recording events. The caller supplies the clock.
pub struct Detector {
    pub cfg: Config,
    /// Since when other apps use the mic or the camera, before a meeting started.
    pending_since: Option<f64>,
    /// When the current meeting started.
    started_at: Option<f64>,
    /// Since when no other app uses the mic or the camera, during a meeting.
    released_since: Option<f64>,
    /// When the offer of the current meeting showed, while it still shows.
    offered_at: Option<f64>,
    /// The user accepted "Record?" for the current meeting.
    recording: bool,
    device_grace_until: f64,
    last_devices: Option<Vec<String>>,
}

impl Detector {
    pub fn new(cfg: Config) -> Self {
        Detector {
            cfg,
            pending_since: None,
            started_at: None,
            released_since: None,
            offered_at: None,
            recording: false,
            device_grace_until: f64::NEG_INFINITY,
            last_devices: None,
        }
    }

    pub fn update(&mut self, s: &Snapshot, now: f64) -> Vec<Event> {
        if self.last_devices.as_ref().is_some_and(|d| *d != s.devices) {
            self.device_grace_until = now + self.cfg.device_change_grace;
        }
        self.last_devices = Some(s.devices.clone());

        let Some(started) = self.started_at else {
            let Some(app) = s.apps.first() else {
                self.pending_since = None; // a use that stops before start_after starts over
                return vec![];
            };
            let since = *self.pending_since.get_or_insert(now);
            if now - since < self.cfg.start_after {
                return vec![];
            }
            self.pending_since = None;
            self.started_at = Some(now);
            self.offered_at = Some(now);
            return vec![Event::OfferRecording(app.clone())];
        };

        if !s.apps.is_empty() {
            self.released_since = None;
        } else {
            let since = *self.released_since.get_or_insert(now);
            if now - since >= self.cfg.end_after
                && now - started >= self.cfg.min_session
                && now >= self.device_grace_until
            {
                let (offered, recording) = (self.offered_at.is_some(), self.recording);
                self.started_at = None;
                self.released_since = None;
                self.offered_at = None;
                self.recording = false;
                return match (recording, offered) {
                    (true, _) => vec![Event::StopRecording],
                    (false, true) => vec![Event::WithdrawOffer],
                    (false, false) => vec![],
                };
            }
        }
        // Like Not now: no new offer until the mic and camera are released and used again.
        if self
            .offered_at
            .is_some_and(|at| now - at >= self.cfg.offer_for)
        {
            self.offered_at = None;
            return vec![Event::WithdrawOffer];
        }
        vec![]
    }

    /// The user clicked "Record?": starts the recording while the meeting runs. A click after
    /// the meeting ended, or a second click, does nothing.
    pub fn accept(&mut self) -> Vec<Event> {
        if self.started_at.is_none() || self.recording {
            return vec![];
        }
        self.recording = true;
        self.offered_at = None;
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
    use std::collections::BTreeMap;

    fn using(apps: &[&str]) -> Snapshot {
        Snapshot {
            apps: apps.iter().map(|a| a.to_string()).collect(),
            ..Default::default()
        }
    }
    fn released() -> Snapshot {
        Snapshot::default()
    }
    fn detector() -> Detector {
        Detector::new(Config::default())
    }
    fn offer(app: &str) -> Event {
        Event::OfferRecording(app.into())
    }
    /// Feeds the same snapshot once per second over [from, to] and collects the events.
    fn run(d: &mut Detector, s: &Snapshot, from: u32, to: u32) -> Vec<Event> {
        (from..=to).flat_map(|t| d.update(s, t as f64)).collect()
    }

    #[test]
    fn offers_to_record_once_another_app_used_the_mic_or_camera_for_five_seconds() {
        // Pavel's rule: the mic or the camera in use by another app means a meeting, whatever
        // the app is.
        for app in ["Zoom", "chrome", "WindowsCamera", "obscure-voip"] {
            let mut d = detector();
            let s = using(&[app]);
            assert_eq!(run(&mut d, &s, 0, 4), vec![], "{app}");
            assert_eq!(
                d.update(&s, 5.0),
                vec![offer(app)],
                "the card names the app"
            );
            assert_eq!(run(&mut d, &s, 6, 19), vec![], "one offer per meeting");
        }
    }

    #[test]
    fn records_only_after_the_record_click() {
        // Pavel's rule: a detected meeting is never recorded on its own, only after one click
        // on "Record?".
        let mut d = detector();
        let call = using(&["Zoom"]);
        assert_eq!(run(&mut d, &call, 0, 10), vec![offer("Zoom")]);
        assert_eq!(d.accept(), vec![Event::StartRecording]);
        assert_eq!(d.accept(), vec![], "a second click starts nothing");
        assert_eq!(
            run(&mut d, &call, 11, 90),
            vec![],
            "a recording offer never times out"
        );
        assert_eq!(run(&mut d, &released(), 91, 95), vec![Event::StopRecording]);
        // The next meeting asks again, and its click records again.
        assert_eq!(run(&mut d, &call, 100, 105), vec![offer("Zoom")]);
        assert_eq!(d.accept(), vec![Event::StartRecording]);
    }

    #[test]
    fn an_unanswered_offer_goes_away_after_twenty_seconds_and_records_nothing() {
        let mut d = detector();
        assert_eq!(d.accept(), vec![], "no meeting, nothing to accept");
        let call = using(&["Zoom"]);
        assert_eq!(run(&mut d, &call, 0, 24), vec![offer("Zoom")]);
        assert_eq!(d.update(&call, 25.0), vec![Event::WithdrawOffer]);
        // Like Not now: no new card while the call goes on, and nothing to hide at its end.
        assert_eq!(run(&mut d, &call, 26, 300), vec![]);
        assert_eq!(run(&mut d, &released(), 301, 310), vec![]);
        assert_eq!(
            d.accept(),
            vec![],
            "a late click after the meeting starts nothing"
        );
        // Released and used again: a new meeting, a new card.
        assert_eq!(run(&mut d, &call, 311, 316), vec![offer("Zoom")]);
    }

    #[test]
    fn a_meeting_ends_four_seconds_after_the_mic_and_camera_are_released() {
        let mut d = detector();
        run(&mut d, &using(&["Zoom"]), 0, 30);
        d.accept();
        assert_eq!(run(&mut d, &released(), 31, 34), vec![]);
        assert_eq!(d.update(&released(), 35.0), vec![Event::StopRecording]);
    }

    #[test]
    fn use_back_within_four_seconds_is_the_same_meeting() {
        let mut d = detector();
        run(&mut d, &using(&["Zoom"]), 0, 30);
        d.accept();
        let mut events = run(&mut d, &released(), 31, 33);
        events.extend(run(&mut d, &using(&["Zoom"]), 34, 49));
        assert_eq!(events, vec![], "no end and no new offer");
        // The next real release gets the full wait again, not the stale time from 31 s.
        assert_eq!(run(&mut d, &released(), 50, 53), vec![]);
        assert_eq!(d.update(&released(), 54.0), vec![Event::StopRecording]);
    }

    #[test]
    fn no_end_in_first_fifteen_seconds() {
        let mut d = detector();
        assert_eq!(run(&mut d, &using(&["Zoom"]), 0, 5), vec![offer("Zoom")]);
        assert_eq!(
            run(&mut d, &released(), 6, 19),
            vec![],
            "meeting only 14 s old"
        );
        assert_eq!(d.update(&released(), 20.0), vec![Event::WithdrawOffer]);
    }

    #[test]
    fn flapping_use_does_not_start() {
        // The mic toggles every 2 s: never in use 5 s in a row.
        let mut d = detector();
        let (on, off) = (using(&["Zoom"]), released());
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
            apps: vec!["Zoom".into()],
            devices: vec!["mic".into(), "speakers".into()],
        };
        run(&mut d, &call, 0, 30);
        assert_eq!(d.accept(), vec![Event::StartRecording]);
        let headset = Snapshot {
            devices: vec!["headset".into(), "headset".into()],
            ..Default::default()
        };
        assert_eq!(
            run(&mut d, &headset, 31, 40),
            vec![],
            "would end at 35 without the change"
        );
        assert_eq!(d.update(&headset, 41.0), vec![Event::StopRecording]);
    }

    #[test]
    fn mic_and_camera_users_overlapping_are_one_meeting() {
        // Zoom on the mic, then the camera app too, then only the camera app: one card, one
        // recording, until nothing uses either.
        let mut d = detector();
        assert_eq!(run(&mut d, &using(&["Zoom"]), 0, 5), vec![offer("Zoom")]);
        assert_eq!(d.accept(), vec![Event::StartRecording]);
        assert_eq!(
            run(&mut d, &using(&["Zoom", "WindowsCamera"]), 6, 30),
            vec![]
        );
        assert_eq!(
            run(&mut d, &using(&["WindowsCamera"]), 31, 60),
            vec![],
            "still in a meeting"
        );
        assert_eq!(run(&mut d, &released(), 61, 65), vec![Event::StopRecording]);
    }

    /// A ConsentStore fixture: key path -> (LastUsedTimeStart, LastUsedTimeStop).
    struct Fixture(BTreeMap<String, (Option<u64>, Option<u64>)>);

    impl Fixture {
        fn new(keys: &[(&str, Option<u64>, Option<u64>)]) -> Fixture {
            let keys = keys
                .iter()
                .map(|(k, start, stop)| (k.to_string(), (*start, *stop)));
            Fixture(keys.collect())
        }
    }

    impl Registry for Fixture {
        fn subkeys(&self, path: &str) -> io::Result<Vec<String>> {
            let prefix = format!(r"{path}\");
            let mut names: Vec<String> = self
                .0
                .keys()
                .filter_map(|k| k.strip_prefix(&prefix))
                .map(|rest| rest.split('\\').next().unwrap().to_string())
                .collect();
            names.dedup();
            Ok(names)
        }
        fn qword(&self, path: &str, name: &str) -> Option<u64> {
            let (start, stop) = self.0.get(path)?;
            match name {
                "LastUsedTimeStart" => *start,
                "LastUsedTimeStop" => *stop,
                _ => None,
            }
        }
    }

    const SHEPETAL: &str = r"C:\Users\pavel\AppData\Local\Programs\Shepetal\shepetal.exe";
    /// A FILETIME, in 100 ns units since 1601.
    const T: Option<u64> = Some(134_000_000_000_000_000);

    #[test]
    fn finds_desktop_and_packaged_apps_using_the_mic_or_camera_now() {
        let reg = Fixture::new(&[
            // In use now: started, stop 0.
            (
                r"microphone\NonPackaged\C:#Users#pavel#AppData#Roaming#Zoom#bin#Zoom.exe",
                T,
                Some(0),
            ),
            (r"webcam\Microsoft.WindowsCamera_8wekyb3d8bbwe", T, Some(0)),
            (r"microphone\MSTeams_8wekyb3d8bbwe", T, Some(0)),
            // Used before, stopped since.
            (
                r"microphone\NonPackaged\C:#Program Files#Google#Chrome#Application#chrome.exe",
                T,
                T,
            ),
            (
                r"webcam\NonPackaged\C:#Program Files#Mozilla Firefox#firefox.exe",
                T,
                T,
            ),
            // Never used, or the values are missing.
            (
                r"microphone\NonPackaged\C:#Users#pavel#AppData#Local#Discord#app-1.0.9#Discord.exe",
                Some(0),
                Some(0),
            ),
            (
                r"microphone\Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe",
                None,
                None,
            ),
            (r"webcam\NonPackaged\C:#Tools#cam.exe", T, None),
        ]);
        let apps = in_use(&reg, Path::new(SHEPETAL)).unwrap();
        assert_eq!(
            apps,
            ["MSTeams", "Zoom", "WindowsCamera"],
            "mic first, then camera"
        );
    }

    #[test]
    fn shepetal_never_counts_by_its_exact_exe_path_only() {
        let reg = Fixture::new(&[
            // Its own always-open mic, whatever the case of the path.
            (
                r"microphone\NonPackaged\c:#users#pavel#appdata#local#programs#shepetal#SHEPETAL.EXE",
                T,
                Some(0),
            ),
            (
                r"webcam\NonPackaged\C:#Users#pavel#AppData#Local#Programs#Shepetal#shepetal.exe",
                T,
                Some(0),
            ),
        ]);
        assert_eq!(in_use(&reg, Path::new(SHEPETAL)).unwrap(), [] as [&str; 0]);
        // Not by name: another app called shepetal.exe, or one whose name holds it, counts.
        let reg = Fixture::new(&[
            (r"microphone\NonPackaged\D:#Other#shepetal.exe", T, Some(0)),
            (
                r"microphone\NonPackaged\C:#Apps#shepetal-notes.exe",
                T,
                Some(0),
            ),
        ]);
        assert_eq!(
            in_use(&reg, Path::new(SHEPETAL)).unwrap(),
            ["shepetal-notes", "shepetal"]
        );
    }

    #[test]
    fn no_consent_store_keys_means_no_app() {
        // A PC where no app ever used the camera has no webcam key.
        let reg = Fixture::new(&[]);
        assert_eq!(in_use(&reg, Path::new(SHEPETAL)).unwrap(), [] as [&str; 0]);
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
