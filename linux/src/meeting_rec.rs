//! Meeting recording in `shepetal daemon` (goal rule 7, docs/re/meetings.md section 7).
//! Every 2 s it reads `pw-dump`. Once a meeting app has held the mic for the start grace, it
//! records the mic and the default sink's monitor into two WAVs. When the call ends, it stops
//! them and writes a Me / Others transcript next to them. The audio is always kept (rule 4).

use serde_json::Value;
use shepetal::{insert, meeting, model};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

const ME: &str = "Me.wav";
const OTHERS: &str = "Others.wav";

/// The start and end thresholds from docs/re/meetings.md (the same as the Mac's
/// `MeetingDetector`), in ms. `SHEPETAL_MEETING_THRESHOLDS="start_after=5,reacquire=4"` (in
/// seconds) overrides them.
#[derive(Debug, Clone, PartialEq)]
struct Thresholds {
    /// How often pw-dump is read.
    poll: u64,
    /// How long a meeting app must hold the mic before recording starts (grace).
    start_after: u64,
    /// No end in the first part of a recording.
    min_session: u64,
    /// The wait after a meeting app lets go of the mic (bound silence) ...
    end_with_evidence: u64,
    /// ... and at least this long: if the mic comes back within it, it is the same meeting.
    reacquire: u64,
    /// A change of the default mic or speakers holds off an end this long.
    device_change: u64,
}

impl Default for Thresholds {
    fn default() -> Self {
        Thresholds { poll: 2000, start_after: 5000, min_session: 15000, end_with_evidence: 3000, reacquire: 4000, device_change: 10000 }
    }
}

impl Thresholds {
    /// The defaults with comma-separated `name=seconds` overrides.
    fn parse(spec: &str) -> Result<Self, String> {
        let mut t = Thresholds::default();
        for kv in spec.split(',').map(str::trim).filter(|s| !s.is_empty()) {
            let (k, v) = kv.split_once('=').ok_or(format!("{kv:?}: want name=seconds"))?;
            let secs = v.trim().parse::<f64>().ok().filter(|s| s.is_finite() && *s >= 0.0).ok_or(format!("{kv:?}: not a number of seconds"))?;
            *match k.trim() {
                "poll" => &mut t.poll,
                "start_after" => &mut t.start_after,
                "min_session" => &mut t.min_session,
                "end_with_evidence" => &mut t.end_with_evidence,
                "reacquire" => &mut t.reacquire,
                "device_change" => &mut t.device_change,
                k => return Err(format!("unknown threshold {k:?}")),
            } = (secs * 1000.0).round() as u64;
        }
        Ok(t)
    }
}

/// What one pw-dump shows: the meeting apps on the mic and the default mic and speakers.
/// shepetal's own recorders are never meeting apps (see `meeting::mic_streams`).
#[derive(Debug, Default, Clone, PartialEq)]
struct Snapshot {
    apps: Vec<&'static str>,
    devices: Vec<String>,
}

fn snapshot(dump: &Value) -> Snapshot {
    let mut apps: Vec<_> = meeting::mic_streams(dump).into_iter().filter_map(|s| s.meeting).collect();
    apps.sort();
    apps.dedup();
    let mut devices: Vec<_> = dump.as_array().into_iter().flatten()
        .filter(|o| o["type"] == "PipeWire:Interface:Metadata" && o["info"]["props"]["metadata.name"] == "default")
        .flat_map(|o| o["metadata"].as_array().into_iter().flatten())
        .filter(|e| e["key"] == "default.audio.sink" || e["key"] == "default.audio.source")
        .map(|e| format!("{}={}", e["key"], e["value"]))
        .collect();
    devices.sort();
    Snapshot { apps, devices }
}

#[derive(Debug, PartialEq)]
enum Step {
    Start,
    Stop,
}

/// Debounced start and stop from snapshots. One recording covers every meeting app on the mic,
/// because the mic and the system audio are shared. The caller supplies the clock (ms).
#[derive(Default)]
struct Detector {
    t: Thresholds,
    candidate_since: Option<u64>,
    started: Option<u64>,
    lost_since: Option<u64>,
    devices: Option<Vec<String>>,
    hold_until: u64,
}

impl Detector {
    fn feed(&mut self, now: u64, s: &Snapshot) -> Option<Step> {
        if self.devices.as_ref().is_some_and(|d| *d != s.devices) {
            self.hold_until = now + self.t.device_change;
        }
        self.devices = Some(s.devices.clone());
        let held = !s.apps.is_empty();
        match self.started {
            // A candidate that drops out before start_after starts over (flapping).
            None if !held => {
                self.candidate_since = None;
                None
            }
            None => {
                let since = *self.candidate_since.get_or_insert(now);
                if now - since < self.t.start_after {
                    return None;
                }
                self.candidate_since = None;
                self.started = Some(now);
                Some(Step::Start)
            }
            Some(_) if held => {
                self.lost_since = None;
                None
            }
            Some(started) => {
                let since = *self.lost_since.get_or_insert(now);
                // Linux sees only mic holders, so a release is always the bound kind of end.
                let wait = self.t.end_with_evidence.max(self.t.reacquire);
                if now - since < wait || now - started < self.t.min_session || now < self.hold_until {
                    return None;
                }
                self.started = None;
                self.lost_since = None;
                Some(Step::Stop)
            }
        }
    }
}

/// `<data_home>/shepetal/meetings/<stamp>/` (0700) with new, empty `Me.wav` and `Others.wav`
/// (0600). It never reuses a folder or file that exists, and refuses a `meetings` dir that is a
/// symlink or open to others, as `shepetal::new_recording` does for dictation clips.
fn new_meeting(data_home: &Path, stamp: u128) -> std::io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    let root = data_home.join("shepetal").join("meetings");
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&root)?;
    let md = std::fs::symlink_metadata(&root)?;
    if !md.is_dir() || md.permissions().mode() & 0o077 != 0 {
        return Err(std::io::Error::other(format!("{} must be a 0700 directory", root.display())));
    }
    let dir = root.join(stamp.to_string());
    // Not recursive: mkdir fails on anything already there, a symlink included.
    std::fs::DirBuilder::new().mode(0o700).create(&dir)?;
    for f in [ME, OTHERS] {
        create_private(&dir.join(f))?;
    }
    Ok(dir)
}

/// O_CREAT|O_EXCL with mode 0600, which also refuses a symlink planted at the path.
fn create_private(p: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(p)
}

/// One channel at 16 kHz mono s16, named `shepetal` like the dictation recorder. `system`
/// records the default sink's monitor. pw-record's `stream.capture.sink` makes WirePlumber link
/// it to the default sink's monitor and follow the default when it changes. parecord takes
/// `@DEFAULT_MONITOR@`.
fn recorder(wav: &Path, system: bool, pw_record: bool) -> Command {
    let mut c = Command::new(if pw_record { "pw-record" } else { "parecord" });
    if pw_record {
        let props = if system { "{ application.name = shepetal stream.capture.sink = true }" } else { "{ application.name = shepetal }" };
        c.args(["--rate", "16000", "--channels", "1", "--format", "s16", "-P", props]);
    } else {
        c.args(["--rate=16000", "--channels=1", "--format=s16le", "--file-format=wav", "--property=application.name=shepetal"]);
        if system {
            c.arg("--device=@DEFAULT_MONITOR@");
        }
    }
    c.arg(wav);
    die_with_parent(&mut c);
    c
}

/// The recorder gets SIGINT when the thread that started it ends. That is the meeting thread,
/// which lives as long as the daemon. So a daemon that exits, even by SIGKILL, does not leave
/// the mic recording, and the WAV header is still written.
#[cfg(target_os = "linux")]
fn die_with_parent(c: &mut Command) {
    use std::os::unix::process::CommandExt;
    extern "C" {
        fn prctl(option: std::ffi::c_int, ...) -> std::ffi::c_int;
    }
    const PR_SET_PDEATHSIG: std::ffi::c_int = 1;
    const SIGINT: std::ffi::c_ulong = 2;
    // SAFETY: prctl is async-signal-safe and touches no memory, as pre_exec requires.
    unsafe {
        c.pre_exec(|| {
            prctl(PR_SET_PDEATHSIG, SIGINT);
            Ok(())
        });
    }
}

#[cfg(not(target_os = "linux"))]
fn die_with_parent(_: &mut Command) {}

/// A meeting being recorded: its folder, the two recorders and every meeting app seen.
struct Session {
    dir: PathBuf,
    me: Child,
    others: Child,
    apps: Vec<&'static str>,
}

fn start(data_home: &Path, pw_record: bool) -> Result<Session, String> {
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis();
    let dir = new_meeting(data_home, stamp).map_err(|e| format!("meeting folder: {e}"))?;
    let spawn = |file, system| recorder(&dir.join(file), system, pw_record).spawn().map_err(|e| format!("meeting recorder: {e}"));
    let me = spawn(ME, false)?;
    let others = match spawn(OTHERS, true) {
        Ok(c) => c,
        Err(e) => {
            crate::stop(me);
            return Err(e);
        }
    };
    Ok(Session { dir, me, others, apps: vec![] })
}

/// The same whisper-cli run as for dictation (`crate::transcribe`), but keeping the segment
/// timestamps (no `-nt`).
fn whisper_cmd(model: &Path, wav: &Path) -> Command {
    let mut c = Command::new("whisper-cli");
    c.arg("-m").arg(model).arg("-f").arg(wav).args(["-np", "-l", "auto"]);
    c
}

fn whisper(model: &Path, wav: &Path) -> Result<Vec<(u64, String)>, String> {
    let out = whisper_cmd(model, wav).output().map_err(|e| format!("whisper-cli: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("whisper-cli: {}", err.trim().lines().last().unwrap_or("failed")));
    }
    Ok(segments(&String::from_utf8_lossy(&out.stdout)))
}

/// whisper-cli prints one `[00:01:02.340 --> 00:01:05.000]  text` line per segment. Returns the
/// start (ms) and text of each, without whisper's non-speech markers.
fn segments(stdout: &str) -> Vec<(u64, String)> {
    let ms = |stamp: &str| -> Option<u64> {
        let mut p = stamp.split(':');
        let (h, m, s) = (p.next()?.parse::<u64>().ok()?, p.next()?.parse::<u64>().ok()?, p.next()?.parse::<f64>().ok()?);
        Some(h * 3_600_000 + m * 60_000 + (s * 1000.0).round() as u64)
    };
    stdout.lines().filter_map(|l| {
        let (from, rest) = l.trim_start().strip_prefix('[')?.split_once(" --> ")?;
        let text = crate::without_markers(rest.split_once(']')?.1).split_whitespace().collect::<Vec<_>>().join(" ");
        Some((ms(from)?, text)).filter(|(_, t)| !t.is_empty())
    }).collect()
}

/// The meeting as Markdown: one `[hh:mm:ss] Speaker: text` paragraph per turn, the channels
/// merged by start time (Me first at the same time), a speaker's consecutive segments joined.
/// Times count from the start of the recording.
fn transcript(apps: &[&str], channels: &[(&str, Vec<(u64, String)>)], notes: &[String]) -> String {
    let mut segs: Vec<_> = channels.iter().flat_map(|(who, s)| s.iter().map(move |(t, x)| (*t, *who, x.as_str()))).collect();
    segs.sort_by_key(|s| s.0); // stable, so the channel order breaks ties
    let mut out = format!("# Meeting\n\n- Apps: {}\n- Audio: {ME} (microphone), {OTHERS} (system audio)\n", apps.join(", "));
    for n in notes {
        out += &format!("- {n}\n");
    }
    let mut last = "";
    for (t, who, text) in segs {
        if who == last {
            out.pop();
            out += &format!(" {text}\n");
            continue;
        }
        let s = t / 1000;
        out += &format!("\n[{:02}:{:02}:{:02}] {who}: {text}\n", s / 3600, s / 60 % 60, s % 60);
        last = who;
    }
    out
}

/// `transcript.md` in the meeting folder, 0600, never over an existing file.
fn save(dir: &Path, md: &str) -> std::io::Result<PathBuf> {
    let path = dir.join("transcript.md");
    create_private(&path)?.write_all(md.as_bytes())?;
    Ok(path)
}

fn write_transcript(dir: &Path, apps: &[&str], model: &Path) {
    let mut channels = vec![];
    let mut notes = vec![];
    for (who, file) in [("Me", ME), ("Others", OTHERS)] {
        match whisper(model, &dir.join(file)) {
            Ok(s) => channels.push((who, s)),
            Err(e) => notes.push(format!("{who} was not transcribed: {e}")),
        }
    }
    for n in &notes {
        eprintln!("shepetal: meeting {}: {n}", dir.display());
    }
    match save(dir, &transcript(apps, &channels, &notes)) {
        Ok(p) => eprintln!("shepetal: meeting transcript {}", p.display()),
        Err(e) => eprintln!("shepetal: meeting transcript in {}: {e}", dir.display()),
    }
}

/// Start the meeting thread. Bad thresholds stop the daemon. Without pw-dump only meeting
/// recording is lost, and the thread says so.
pub fn spawn(stt: &model::Choice) -> Result<(), String> {
    let t = Thresholds::parse(&crate::env("SHEPETAL_MEETING_THRESHOLDS")).map_err(|e| format!("SHEPETAL_MEETING_THRESHOLDS: {e}"))?;
    let data_home = PathBuf::from(crate::data_home());
    // The final pass is Whisper on the whole files (docs/re/meetings.md section 7): the dictation
    // model when it is Whisper, else Whisper turbo next to the dictation model.
    let model = match stt.engine {
        model::Engine::Whisper => crate::model_path(stt),
        _ => data_home.join("shepetal").join(model::TURBO_Q5),
    };
    if !model.exists() || !insert::on_path("whisper-cli") {
        eprintln!("shepetal: meetings are recorded but not transcribed until whisper-cli and {} are installed", model.display());
    }
    eprintln!("shepetal: meeting detection on, {t:?} ms (SHEPETAL_MEETING_THRESHOLDS)");
    std::thread::spawn(move || run(&t, &data_home, &model));
    Ok(())
}

fn run(t: &Thresholds, data_home: &Path, model: &Path) {
    // ponytail: polls pw-dump; `pw-dump --monitor` or a registry listener reacts sooner.
    let pw_record = insert::on_path("pw-record");
    let t0 = Instant::now();
    let mut det = Detector { t: t.clone(), ..Default::default() };
    let mut rec: Option<Session> = None;
    let mut warned = false;
    loop {
        std::thread::sleep(Duration::from_millis(t.poll));
        let out = match Command::new("pw-dump").output() {
            Ok(o) => o,
            Err(e) => return eprintln!("shepetal: meetings are not detected: pw-dump: {e}"),
        };
        let dump = match serde_json::from_slice::<Value>(&out.stdout) {
            Ok(d) => d,
            Err(e) => {
                if !std::mem::replace(&mut warned, true) {
                    eprintln!("shepetal: pw-dump gave no JSON ({e}); is PipeWire running?");
                }
                continue;
            }
        };
        warned = false;
        let snap = snapshot(&dump);
        match det.feed(t0.elapsed().as_millis() as u64, &snap) {
            Some(Step::Start) => match start(data_home, pw_record) {
                Ok(s) => {
                    eprintln!("shepetal: meeting ({}) recording to {}, system audio {:?}", snap.apps.join(", "), s.dir.display(), meeting::system_audio_source(&dump));
                    rec = Some(s);
                }
                Err(e) => eprintln!("shepetal: meeting not recorded: {e}"),
            },
            Some(Step::Stop) => {
                if let Some(Session { dir, me, others, apps }) = rec.take() {
                    crate::stop(me);
                    crate::stop(others);
                    eprintln!("shepetal: meeting ended, transcribing {}", dir.display());
                    let model = model.to_path_buf();
                    // Its own thread, so a long transcription does not hold up the next meeting.
                    std::thread::spawn(move || write_transcript(&dir, &apps, &model));
                }
            }
            None => {}
        }
        if let Some(s) = rec.as_mut() {
            for a in &snap.apps {
                if !s.apps.contains(a) {
                    s.apps.push(a);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use Step::*;

    /// A running capture stream as pw-dump prints it.
    fn mic(app: &str, binary: &str) -> Value {
        json!({ "type": "PipeWire:Interface:Node", "info": { "state": "running", "props": {
            "media.class": "Stream/Input/Audio", "application.name": app, "application.process.binary": binary } } })
    }

    /// A pw-dump with these capture streams and `source` as the default mic.
    fn pw(streams: &[Value], source: &str) -> Value {
        let mut objs = vec![json!({ "type": "PipeWire:Interface:Metadata", "info": { "props": { "metadata.name": "default" } },
            "metadata": [
                { "subject": 0, "key": "default.audio.sink", "value": { "name": "alsa_output.analog-stereo" } },
                { "subject": 0, "key": "default.audio.source", "value": { "name": source } } ] })];
        objs.extend_from_slice(streams);
        Value::Array(objs)
    }

    fn dump(streams: &[Value], source: &str) -> Snapshot {
        snapshot(&pw(streams, source))
    }

    fn zoom() -> Value {
        mic("ZOOM VoiceEngine", "zoom")
    }

    fn firefox() -> Value {
        mic("Firefox", "firefox")
    }

    /// The streams shepetal itself opens while a meeting records: Me.wav, Others.wav (on the sink
    /// monitor) and a dictation.
    fn own() -> Vec<Value> {
        let mut monitor = mic("shepetal", "pw-record");
        monitor["info"]["props"]["stream.capture.sink"] = json!(true);
        vec![mic("shepetal", "pw-record"), monitor, mic("shepetal", "pw-record")]
    }

    const BUILTIN: &str = "alsa_input.analog-stereo";

    /// Feed one snapshot per 2 s poll and return the steps with their times.
    fn play(det: &mut Detector, seq: &[Snapshot]) -> Vec<(u64, Step)> {
        seq.iter().enumerate().filter_map(|(i, s)| det.feed(i as u64 * 2000, s).map(|st| (i as u64 * 2000, st))).collect()
    }

    fn times(s: &Snapshot, n: usize) -> Vec<Snapshot> {
        vec![s.clone(); n]
    }

    #[test]
    fn starts_once_a_meeting_app_held_the_mic_for_the_grace() {
        // docs/re/meetings.md 2.3: 5 s grace. Seen at 0, 2, 4 and 6 s: the start comes at 6 s,
        // never earlier, and only once.
        let z = dump(&[zoom()], BUILTIN);
        assert_eq!(z.apps, ["Zoom"]);
        assert_eq!(play(&mut Detector::default(), &times(&z, 6)), [(6000, Start)]);
    }

    #[test]
    fn ends_after_reacquire_and_never_in_the_first_15_s() {
        // 2.4: no end in the first 15 s, then 4 s without the holder (reacquire beats the 3 s
        // bound silence).
        let (z, idle) = (dump(&[zoom()], BUILTIN), dump(&[], BUILTIN));
        let mut seq = times(&z, 16); // 0..30 s, started at 6 s
        seq.extend(times(&idle, 4)); // gone from 32 s
        assert_eq!(play(&mut Detector::default(), &seq), [(6000, Start), (36000, Stop)]);

        // Zoom gone right after the start: the end waits for 6 + 15 s, the first poll at 22 s.
        let mut seq = times(&z, 4);
        seq.extend(times(&idle, 10));
        assert_eq!(play(&mut Detector::default(), &seq), [(6000, Start), (22000, Stop)]);
    }

    #[test]
    fn flapping_restarts_the_grace_and_does_not_end_a_call() {
        let (z, idle) = (dump(&[zoom()], BUILTIN), dump(&[], BUILTIN));
        // A 2 s grab, a miss at 4 s, then back from 6 s: the grace counts from 6 s, start at 12 s.
        let mut seq = [times(&z, 2), times(&idle, 1), times(&z, 4)].concat();
        // In the call the holder misses every other poll (14..72 s): under 4 s each, no end.
        for _ in 0..15 {
            seq.extend([z.clone(), idle.clone()]);
        }
        // Gone for good from the last miss at 72 s: the end is 4 s later.
        seq.extend(times(&idle, 3));
        assert_eq!(play(&mut Detector::default(), &seq), [(12000, Start), (76000, Stop)]);
    }

    #[test]
    fn two_apps_are_one_meeting_until_both_let_go() {
        let both = dump(&[zoom(), firefox()], BUILTIN);
        assert_eq!(both.apps, ["Browser (Firefox)", "Zoom"]);
        let mut seq = times(&both, 10); // 0..18 s
        seq.extend(times(&dump(&[firefox()], BUILTIN), 10)); // Zoom left at 20 s, Firefox stays
        seq.extend(times(&dump(&[], BUILTIN), 3)); // both gone at 40 s
        assert_eq!(play(&mut Detector::default(), &seq), [(6000, Start), (44000, Stop)]);
    }

    #[test]
    fn shepetal_own_streams_never_start_or_hold_a_meeting() {
        // While a meeting records, shepetal holds the mic twice (Me.wav, a dictation) and the sink
        // monitor once (Others.wav). Counted, they would keep the recording on after the call,
        // forever. They are not even mic users: Me.wav and the dictation by name, Others.wav as
        // a monitor.
        assert_eq!(meeting::mic_streams(&pw(&own(), BUILTIN)), []);
        let own_only = dump(&own(), BUILTIN);
        assert_eq!(play(&mut Detector::default(), &times(&own_only, 20)), []);

        let mut with_zoom = own();
        with_zoom.push(zoom());
        let mut seq = times(&dump(&with_zoom, BUILTIN), 16);
        seq.extend(times(&own_only, 4));
        assert_eq!(play(&mut Detector::default(), &seq), [(6000, Start), (36000, Stop)]);
    }

    #[test]
    fn a_device_change_holds_off_the_end_for_10_s() {
        // A headset plugged in mid-call: the call app may drop the mic while it moves over.
        let mut seq = times(&dump(&[zoom()], BUILTIN), 16); // 0..30 s
        seq.extend(times(&dump(&[], "bluez_input.headset"), 6)); // 32 s: new default mic, no holder
        assert_eq!(play(&mut Detector::default(), &seq), [(6000, Start), (42000, Stop)]);
    }

    #[test]
    fn thresholds_are_tunable_in_seconds() {
        assert_eq!(Thresholds::parse(""), Ok(Thresholds::default()));
        let t = Thresholds::parse("start_after=0, reacquire=8.5").unwrap();
        assert_eq!((t.start_after, t.reacquire, t.min_session), (0, 8500, 15000));
        assert_eq!(play(&mut Detector { t, ..Default::default() }, &[dump(&[zoom()], BUILTIN)]), [(0, Start)]);
        // Either end wait, raised, moves the end of a call that left at 32 s.
        for spec in ["reacquire=10", "end_with_evidence=10"] {
            let mut seq = times(&dump(&[zoom()], BUILTIN), 16);
            seq.extend(times(&dump(&[], BUILTIN), 6));
            let t = Thresholds::parse(spec).unwrap();
            assert_eq!(play(&mut Detector { t, ..Default::default() }, &seq), [(6000, Start), (42000, Stop)], "{spec}");
        }
        for bad in ["startafter=5", "reacquire", "reacquire=-1", "reacquire=soon"] {
            assert!(Thresholds::parse(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn the_committed_pw_dump_fixture_is_a_meeting() {
        let d: Value = serde_json::from_str(include_str!("../fixtures/pw-dump-meeting.json")).unwrap();
        let s = snapshot(&d);
        assert_eq!(s.apps, ["Browser (Firefox)", "Zoom"]);
        assert_eq!(s.devices.len(), 2, "{:?}", s.devices);
    }

    #[test]
    fn meeting_audio_is_owner_only_and_never_reused() {
        // Goal rule 4: 0700 dirs, 0600 files, O_EXCL. Under the data home, never /tmp: the daemon
        // passes `crate::data_home()`, which ignores a relative or empty XDG_DATA_HOME.
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("shepetal-meet-{}", std::process::id()));
        let mode = |p: &Path| std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o777;
        let dir = new_meeting(&home, 42).unwrap();
        assert_eq!(dir, home.join("shepetal/meetings/42"));
        assert_eq!((mode(&dir), mode(dir.parent().unwrap())), (0o700, 0o700));
        for f in [ME, OTHERS] {
            assert_eq!(mode(&dir.join(f)), 0o600, "{f}");
        }
        assert!(new_meeting(&home, 42).is_err(), "an existing meeting folder is never reused");

        let md = save(&dir, "# Meeting\n").unwrap();
        assert_eq!((mode(&md), std::fs::read_to_string(&md).unwrap().as_str()), (0o600, "# Meeting\n"));
        assert!(save(&dir, "other").is_err(), "an existing transcript is never overwritten");

        let root = home.join("shepetal/meetings");
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o750)).unwrap();
        assert!(new_meeting(&home, 43).unwrap_err().to_string().contains("must be a 0700 directory"));
        assert!(!root.join("43").exists());

        // A meetings dir swapped for a symlink to a dir others can read is refused too.
        std::fs::remove_dir_all(&root).unwrap();
        std::fs::create_dir_all(home.join("elsewhere")).unwrap();
        std::fs::set_permissions(home.join("elsewhere"), std::fs::Permissions::from_mode(0o700)).unwrap();
        std::os::unix::fs::symlink(home.join("elsewhere"), &root).unwrap();
        assert!(new_meeting(&home, 44).is_err());
        assert_eq!(std::fs::read_dir(home.join("elsewhere")).unwrap().count(), 0);
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn recorders_take_the_mic_and_the_default_sink_monitor() {
        let argv = |c: Command| std::iter::once(c.get_program()).chain(c.get_args()).map(|a| a.to_string_lossy().into_owned()).collect::<Vec<_>>().join(" ");
        let wav = Path::new("/home/me/.local/share/shepetal/meetings/1/Me.wav");
        let pw = "pw-record --rate 16000 --channels 1 --format s16 -P";
        assert_eq!(argv(recorder(wav, false, true)), format!("{pw} {{ application.name = shepetal }} {}", wav.display()));
        assert_eq!(argv(recorder(wav, true, true)), format!("{pw} {{ application.name = shepetal stream.capture.sink = true }} {}", wav.display()));
        let pa = "parecord --rate=16000 --channels=1 --format=s16le --file-format=wav --property=application.name=shepetal";
        assert_eq!(argv(recorder(wav, false, false)), format!("{pa} {}", wav.display()), "the mic is the default source");
        assert_eq!(argv(recorder(wav, true, false)), format!("{pa} --device=@DEFAULT_MONITOR@ {}", wav.display()));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_recorder_gets_sigint_when_the_daemon_goes() {
        let d = std::env::temp_dir().join(format!("shepetal-pdeath-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let (ready, got) = (d.join("ready"), d.join("int"));
        let script = format!("trap 'echo int > {}; exit 0' INT; touch {}; i=0; while [ $i -lt 500 ]; do sleep 0.01; i=$((i+1)); done; exit 3", got.display(), ready.display());
        let waiter = ready.clone();
        let mut child = std::thread::spawn(move || {
            let mut c = Command::new("/bin/sh");
            c.args(["-c", &script]);
            die_with_parent(&mut c);
            let child = c.spawn().unwrap();
            while !waiter.exists() {
                std::thread::sleep(Duration::from_millis(10));
            }
            child
        }).join().unwrap(); // the thread that started it is gone now
        let status = child.wait().unwrap();
        assert!(status.success(), "no SIGINT within 5 s of the thread's end: {status}");
        assert_eq!(std::fs::read_to_string(&got).unwrap(), "int\n");
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn a_meeting_is_recorded_stopped_and_transcribed() {
        // The whole loop against fake pw-dump, pw-record and whisper-cli. It runs in a child copy
        // of this test binary, because the tests in main.rs swap PATH for their own fakes.
        const HOME: &str = "SHEPETAL_TEST_MEETING_HOME";
        if let Ok(home) = std::env::var(HOME) {
            let home = PathBuf::from(home);
            let t = Thresholds::parse("poll=0.1,start_after=0.3,min_session=0.5,reacquire=0.3").unwrap();
            let h = home.clone();
            std::thread::spawn(move || run(&t, &h, Path::new("/models/ggml.bin")));
            for _ in 0..400 {
                let dirs = std::fs::read_dir(home.join("shepetal/meetings")).into_iter().flatten().flatten();
                if dirs.into_iter().any(|e| e.path().join("transcript.md").exists()) {
                    return std::thread::sleep(Duration::from_millis(200)); // let the write finish
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            panic!("no transcript.md within 20 s");
        }
        use std::os::unix::fs::PermissionsExt;
        let d = std::env::temp_dir().join(format!("shepetal-meet-e2e-{}", std::process::id()));
        std::fs::create_dir_all(d.join("bin")).unwrap();
        let (dd, call, idle) = (d.display(), pw(&[zoom()], BUILTIN), pw(&[], BUILTIN));
        let tools = [
            // The call holds the mic for the first 12 reads, then it is gone.
            ("pw-dump", format!("n=$(cat {dd}/reads 2>/dev/null || echo 0); echo $((n+1)) > {dd}/reads\n\
                [ $n -lt 12 ] && printf '%s' '{call}' || printf '%s' '{idle}'\n")),
            // Like pw-record: "RIFF final" only once SIGINT finishes the header.
            ("pw-record", format!("exec >/dev/null 2>&1\nfor f; do :; done\necho \"$*\" >> {dd}/rec.args\n\
                trap 'printf \"RIFF final\" > \"$f\"; exit 0' INT\nprintf 'RIFF partial' > \"$f\"\n\
                i=0; while [ $i -lt 3000 ]; do sleep 0.01; i=$((i+1)); done\n")),
            ("whisper-cli", format!("cat \"$4\" >> {dd}/heard\ncase \"$4\" in\n\
                *Me.wav) printf '\\n[00:00:01.000 --> 00:00:02.000]   Hello from me.\\n' ;;\n\
                *) printf '\\n[00:00:01.500 --> 00:00:03.000]   Hi from them. [Music]\\n' ;;\nesac\n")),
        ];
        for (bin, body) in tools {
            std::fs::write(d.join("bin").join(bin), format!("#!/bin/sh\n{body}")).unwrap();
            std::fs::set_permissions(d.join("bin").join(bin), std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let out = Command::new(std::env::current_exe().unwrap())
            .args(["meeting_rec::tests::a_meeting_is_recorded_stopped_and_transcribed", "--exact", "--nocapture"])
            .env("PATH", format!("{dd}/bin:{}", std::env::var("PATH").unwrap_or_default()))
            .env(HOME, d.join("home"))
            .output().unwrap();
        let log = String::from_utf8_lossy(&out.stderr).into_owned() + &String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "{log}");

        let dirs: Vec<_> = std::fs::read_dir(d.join("home/shepetal/meetings")).unwrap().flatten().map(|e| e.path()).collect();
        assert_eq!(dirs.len(), 1, "one call, one meeting: {dirs:?}");
        let dir = &dirs[0];
        let read = |f: &str| std::fs::read_to_string(dir.join(f)).unwrap();
        assert_eq!((read(ME), read(OTHERS)), ("RIFF final".into(), "RIFF final".into()), "both stopped by SIGINT and kept");
        assert_eq!(std::fs::read_to_string(d.join("heard")).unwrap(), "RIFF finalRIFF final", "whisper read the finished files");
        let rec = std::fs::read_to_string(d.join("rec.args")).unwrap();
        // Both start at once, so either may log first.
        let mut files: Vec<_> = rec.lines().map(|l| (l.rsplit('/').next().unwrap(), l.contains("stream.capture.sink = true"))).collect();
        files.sort();
        assert_eq!(files, [(ME, false), (OTHERS, true)], "only Others.wav records the sink monitor: {rec}");
        assert_eq!(read("transcript.md"), "# Meeting\n\n- Apps: Zoom\n- Audio: Me.wav (microphone), Others.wav (system audio)\n\n\
            [00:00:01] Me: Hello from me.\n\n[00:00:01] Others: Hi from them.\n");
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!([mode(dir), mode(&dir.join(ME)), mode(&dir.join("transcript.md"))], [0o700, 0o600, 0o600]);
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn whisper_keeps_timestamps_and_drops_markers() {
        let args: Vec<_> = whisper_cmd(Path::new("/m.bin"), Path::new("/w/Me.wav")).get_args().map(|a| a.to_string_lossy().into_owned()).collect();
        assert_eq!(args, ["-m", "/m.bin", "-f", "/w/Me.wav", "-np", "-l", "auto"], "no -nt: the transcript needs the times");
        // The shape whisper-cli v1.8 prints on stdout, blank first line included.
        let out = "\n[00:00:00.000 --> 00:00:02.480]   Hello, can you hear me?\n[00:00:02.480 --> 00:00:04.000]   [BLANK_AUDIO]\n\
                   [01:02:03.450 --> 01:02:05.000]   Yes. [Music]  Loud and clear.\nnot a segment\n";
        assert_eq!(segments(out), [(0, "Hello, can you hear me?".to_string()), (3_723_450, "Yes. Loud and clear.".to_string())]);
    }

    #[test]
    fn transcript_interleaves_me_and_others_by_time() {
        let s = |v: &[(u64, &str)]| v.iter().map(|(t, x)| (*t, x.to_string())).collect::<Vec<_>>();
        let me = s(&[(1_000, "Hello, can you hear me?"), (2_400, "Good."), (3_100, "I'll send the notes."), (3_725_000, "Bye.")]);
        let others = s(&[(1_000, "Yes."), (5_900, "Thanks.")]);
        assert_eq!(transcript(&["Zoom", "Browser (Firefox)"], &[("Me", me.clone()), ("Others", others)], &[]), "\
# Meeting

- Apps: Zoom, Browser (Firefox)
- Audio: Me.wav (microphone), Others.wav (system audio)

[00:00:01] Me: Hello, can you hear me?

[00:00:01] Others: Yes.

[00:00:02] Me: Good. I'll send the notes.

[00:00:05] Others: Thanks.

[01:02:05] Me: Bye.
");
        // A channel whisper could not read is named, not left out silently.
        let t = transcript(&["Zoom"], &[("Me", me)], &["Others was not transcribed: whisper-cli: not found".into()]);
        assert!(t.contains("\n- Others was not transcribed: whisper-cli: not found\n\n[00:00:01] Me: Hello"), "{t}");
    }
}
