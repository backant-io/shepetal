//! Meeting recording in `shepetal daemon` (goal rule 7, docs/re/meetings.md section 7).
//! Every 2 s it reads `pw-dump` and /proc. Once any other app has used the mic or the camera for
//! the start grace, it shows a Record? notification. Only a click on Record starts the recording of the mic and
//! the default sink's monitor into two WAVs (`{"meetings": {"auto_record": true}}` in config.json
//! records without asking). When the call ends, it stops them and writes a Me / Others transcript next to them.
//! The audio is always kept (rule 4).

use serde_json::Value;
use shepetal::{insert, meeting, model, shortcuts};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
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
    /// How long another app must use the mic or the camera before the Record? prompt (grace).
    start_after: u64,
    /// No end in the first part of a recording.
    min_session: u64,
    /// The wait after the last app lets go of the mic and the camera (bound silence) ...
    end_with_evidence: u64,
    /// ... and at least this long: if either comes back within it, it is the same meeting.
    reacquire: u64,
    /// A change of the default mic or speakers holds off an end this long.
    device_change: u64,
    /// An unanswered Record? prompt is withdrawn after this long, and nothing is recorded.
    prompt: u64,
}

impl Default for Thresholds {
    fn default() -> Self {
        Thresholds { poll: 2000, start_after: 5000, min_session: 15000, end_with_evidence: 3000, reacquire: 4000, device_change: 10000, prompt: 20000 }
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
                "prompt" => &mut t.prompt,
                k => return Err(format!("unknown threshold {k:?}")),
            } = (secs * 1000.0).round() as u64;
        }
        Ok(t)
    }
}

/// "Always record automatically": `{"meetings": {"auto_record": true}}` in config.json (the
/// daemon's one settings file, `shortcuts::config_file`) records every detected meeting without
/// asking. Missing or false (the default) asks first with the Record? prompt. As for the
/// shortcuts, other features' keys are skipped, and a typo or a wrong type is an error.
fn auto_record(json: &str) -> Result<bool, String> {
    let v: Value = if json.trim().is_empty() { Value::Null } else { serde_json::from_str(json).map_err(|e| e.to_string())? };
    let mut auto = false;
    if let Some(m) = v.get("meetings") {
        for (k, val) in m.as_object().ok_or("\"meetings\" must be an object")? {
            match k.as_str() {
                "auto_record" => auto = val.as_bool().ok_or("meetings.auto_record: expected true or false")?,
                k => return Err(format!("unknown meetings setting {k:?} (auto_record)")),
            }
        }
    }
    Ok(auto)
}

/// `auto_record` from the config file. A missing file means the default (ask first).
fn load_auto_record(path: &Path) -> Result<bool, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    auto_record(&text).map_err(|e| format!("{}: {e}", path.display()))
}

/// The Record? prompt: a desktop notification (org.freedesktop.Notifications, through
/// notify-send) with one Record button. notify-send waits for the answer and prints `record`
/// when Record is clicked. A dismissed or expired notification prints nothing. SIGINT makes
/// notify-send close the notification.
fn prompt_cmd(who: &str, what: &str, timeout_ms: u64) -> Command {
    let mut c = Command::new("notify-send");
    c.args(["--app-name=shepetal", "--action=record=Record", &format!("--expire-time={timeout_ms}"), "Record this meeting?"])
        .arg(format!("{who} is using the {what}. Nothing is recorded unless you click Record."))
        .stdout(Stdio::piped());
    die_with_parent(&mut c);
    c
}

/// What one poll shows: the apps on the mic and on the camera ("" for one nothing names), and
/// the default mic and speakers. shepetal's own processes are never among them
/// (`meeting::own_pids`).
#[derive(Debug, Default, Clone, PartialEq)]
struct Snapshot {
    mic: Vec<String>,
    cam: Vec<String>,
    devices: Vec<String>,
}

/// `proc` is /proc, for the camera fallback and for which processes are ours.
fn snapshot(dump: &Value, proc: &Path) -> Snapshot {
    let own = meeting::own_pids(proc, std::process::id());
    let names = |v: Vec<meeting::Stream>| {
        let mut n: Vec<_> = v.into_iter().map(|s| s.app).collect();
        n.sort();
        n.dedup();
        n
    };
    let (mic, cam) = (names(meeting::mic_streams(dump, &own)), names(meeting::camera_users(dump, proc, &own)));
    let mut devices: Vec<_> = dump.as_array().into_iter().flatten()
        .filter(|o| o["type"] == "PipeWire:Interface:Metadata" && o["info"]["props"]["metadata.name"] == "default")
        .flat_map(|o| o["metadata"].as_array().into_iter().flatten())
        .filter(|e| e["key"] == "default.audio.sink" || e["key"] == "default.audio.source")
        .map(|e| format!("{}={}", e["key"], e["value"]))
        .collect();
    devices.sort();
    Snapshot { mic, cam, devices }
}

/// The apps for the prompt and the log ("Zoom, Firefox", or "An app" when none is named) and
/// what they use. App names only, never a window title, tab or URL.
fn who(s: &Snapshot) -> (String, &'static str) {
    let mut names: Vec<&str> = s.mic.iter().chain(&s.cam).map(String::as_str).filter(|a| !a.is_empty()).collect();
    names.sort();
    names.dedup();
    let what = match (s.mic.is_empty(), s.cam.is_empty()) {
        (false, false) => "microphone and camera",
        (false, true) => "microphone",
        _ => "camera",
    };
    (if names.is_empty() { "An app".into() } else { names.join(", ") }, what)
}

#[derive(Debug, PartialEq)]
enum Step {
    Start,
    Stop,
}

/// Debounced start and stop from snapshots. One recording covers every app on the mic or the
/// camera, because the mic and the system audio are shared. The caller supplies the clock (ms).
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
        let held = !s.mic.is_empty() || !s.cam.is_empty();
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
                // Linux sees only mic and camera users, so a release is always the bound kind of end.
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

/// A meeting being recorded: its folder, the two recorders and every app seen on the mic or camera.
struct Session {
    dir: PathBuf,
    me: Child,
    others: Child,
    apps: Vec<String>,
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
    let apps = if apps.is_empty() { "not named".into() } else { apps.join(", ") };
    let mut out = format!("# Meeting\n\n- Apps: {apps}\n- Audio: {ME} (microphone), {OTHERS} (system audio)\n");
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

fn write_transcript(dir: &Path, apps: &[String], model: &Path) {
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
    let apps: Vec<_> = apps.iter().map(String::as_str).collect();
    match save(dir, &transcript(&apps, &channels, &notes)) {
        Ok(p) => eprintln!("shepetal: meeting transcript {}", p.display()),
        Err(e) => eprintln!("shepetal: meeting transcript in {}: {e}", dir.display()),
    }
}

/// Start the meeting thread. Bad thresholds stop the daemon. Without pw-dump only meeting
/// recording is lost, and the thread says so.
pub fn spawn(stt: &model::Choice) -> Result<(), String> {
    let t = Thresholds::parse(&crate::env("SHEPETAL_MEETING_THRESHOLDS")).map_err(|e| format!("SHEPETAL_MEETING_THRESHOLDS: {e}"))?;
    let config = shortcuts::config_file(std::env::var("XDG_CONFIG_HOME").ok().as_deref(), &crate::env("HOME"));
    let auto = load_auto_record(&config)?;
    // Checked on PATH: Rust 1.75 (Ubuntu 24.04) spawns a missing program as a child that exits
    // 127, so a spawn error alone would not say that the tool is missing.
    if !insert::on_path("pw-dump") || !(insert::on_path("pw-record") || insert::on_path("parecord")) {
        eprintln!("shepetal: meetings are not recorded: install pw-dump and pw-record (pipewire-bin), or parecord");
        return Ok(());
    }
    if !auto && !insert::on_path("notify-send") {
        eprintln!("shepetal: meetings are not recorded: the Record? prompt needs notify-send (libnotify-bin), or put {{\"meetings\": {{\"auto_record\": true}}}} in {} to record every meeting without asking", config.display());
        return Ok(());
    }
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
    let how = if auto { "recording every meeting (meetings.auto_record)" } else { "asking before each recording" };
    eprintln!("shepetal: meeting detection on, {how}, {t:?} ms (SHEPETAL_MEETING_THRESHOLDS)");
    std::thread::spawn(move || run(&t, auto, &data_home, &model, Path::new("/proc")));
    Ok(())
}

fn run(t: &Thresholds, auto_record: bool, data_home: &Path, model: &Path, proc: &Path) {
    // ponytail: polls pw-dump; `pw-dump --monitor` or a registry listener reacts sooner. A click
    // on Record is also seen at the next poll, so up to `poll` late.
    let pw_record = insert::on_path("pw-record");
    let t0 = Instant::now();
    let mut det = Detector { t: t.clone(), ..Default::default() };
    let mut rec: Option<Session> = None;
    // The Record? prompt waiting for an answer, and when it was shown.
    let mut asking: Option<(Child, u64)> = None;
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
        let snap = snapshot(&dump, proc);
        let (apps, what) = who(&snap);
        let now = t0.elapsed().as_millis() as u64;
        let mut begin = false;
        match det.feed(now, &snap) {
            Some(Step::Start) if auto_record => begin = true,
            Some(Step::Start) => match prompt_cmd(&apps, what, t.prompt).spawn() {
                Ok(c) => {
                    eprintln!("shepetal: meeting detected ({apps} on the {what}), asking: Record this meeting?");
                    asking = Some((c, now));
                }
                Err(e) => eprintln!("shepetal: meeting not recorded: notify-send: {e}"),
            },
            Some(Step::Stop) => {
                if let Some((c, _)) = asking.take() {
                    crate::stop(c); // the call ended before an answer: withdraw the prompt
                    eprintln!("shepetal: meeting ended before Record was clicked, nothing recorded");
                }
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
        if let Some((mut c, since)) = asking.take() {
            match c.try_wait() {
                Ok(None) if now - since < t.prompt => asking = Some((c, since)),
                Ok(None) => {
                    crate::stop(c);
                    eprintln!("shepetal: meeting not recorded: Record was not clicked within {} s", t.prompt / 1000);
                }
                Ok(Some(status)) => {
                    let mut out = String::new();
                    let _ = c.stdout.take().map(|mut o| o.read_to_string(&mut out));
                    match out.trim() {
                        "record" => begin = true,
                        _ if status.success() => eprintln!("shepetal: meeting not recorded: the Record? prompt was dismissed"),
                        _ => eprintln!("shepetal: meeting not recorded: notify-send failed ({status}). The Record? prompt needs a notification daemon and libnotify 0.7.10 or later, or set meetings.auto_record in config.json"),
                    }
                }
                Err(e) => eprintln!("shepetal: meeting not recorded: notify-send: {e}"),
            }
        }
        if begin {
            match start(data_home, pw_record) {
                Ok(s) => {
                    eprintln!("shepetal: meeting ({apps} on the {what}) recording to {}, system audio {:?}", s.dir.display(), meeting::system_audio_source(&dump));
                    rec = Some(s);
                }
                Err(e) => eprintln!("shepetal: meeting not recorded: {e}"),
            }
        }
        if let Some(s) = rec.as_mut() {
            for a in snap.mic.iter().chain(&snap.cam).filter(|a| !a.is_empty()) {
                if !s.apps.contains(a) {
                    s.apps.push(a.clone());
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

    /// No /proc: no camera fallback, and only this process is ours.
    const NO_PROC: &str = "/nonexistent/shepetal-proc";

    fn dump(streams: &[Value], source: &str) -> Snapshot {
        snapshot(&pw(streams, source), Path::new(NO_PROC))
    }

    fn zoom() -> Value {
        mic("ZOOM VoiceEngine", "zoom")
    }

    /// Firefox on a running PipeWire camera: the camera node, Firefox's stream and their link.
    fn firefox_cam() -> Vec<Value> {
        vec![
            json!({ "id": 900, "type": "PipeWire:Interface:Node", "info": { "state": "running", "props": {
                "media.class": "Video/Source", "device.api": "v4l2" } } }),
            json!({ "id": 901, "type": "PipeWire:Interface:Node", "info": { "state": "running", "props": {
                "media.class": "Stream/Input/Video", "application.name": "Firefox" } } }),
            json!({ "id": 902, "type": "PipeWire:Interface:Link", "info": { "output-node-id": 900, "input-node-id": 901 } }),
        ]
    }

    /// The streams shepetal itself opens while a meeting records: Me.wav, Others.wav (on the sink
    /// monitor) and a dictation, all from this process's pid.
    fn own() -> Vec<Value> {
        let mut rec = mic("shepetal", "pw-record");
        rec["info"]["props"]["application.process.id"] = json!(std::process::id());
        let mut monitor = rec.clone();
        monitor["info"]["props"]["stream.capture.sink"] = json!(true);
        vec![rec.clone(), monitor, rec]
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
    fn starts_once_another_app_used_the_mic_or_the_camera_for_the_grace() {
        // docs/re/meetings.md 2.3: 5 s grace. Seen at 0, 2, 4 and 6 s: the start comes at 6 s,
        // never earlier, and only once.
        let z = dump(&[zoom()], BUILTIN);
        assert_eq!((z.mic.clone(), z.cam.len()), (vec!["ZOOM VoiceEngine".to_string()], 0));
        assert_eq!(play(&mut Detector::default(), &times(&z, 6)), [(6000, Start)]);
        // Any app counts, not only call apps, and the camera alone is enough.
        assert_eq!(play(&mut Detector::default(), &times(&dump(&[mic("GNOME Sound Recorder", "gnome-sound-recorder")], BUILTIN), 6)), [(6000, Start)]);
        let c = dump(&firefox_cam(), BUILTIN);
        assert_eq!((c.mic.len(), c.cam.clone()), (0, vec!["Firefox".to_string()]));
        assert_eq!(play(&mut Detector::default(), &times(&c, 6)), [(6000, Start)]);
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

        // Used again after the end (40 s) is a new meeting with a new prompt, also after Not now.
        let mut seq = times(&z, 16);
        seq.extend(times(&idle, 4));
        seq.extend(times(&z, 4));
        assert_eq!(play(&mut Detector::default(), &seq), [(6000, Start), (36000, Stop), (46000, Start)]);
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
    fn mic_and_camera_are_one_meeting_until_both_are_free() {
        let mut streams = vec![zoom()];
        streams.extend(firefox_cam());
        let both = dump(&streams, BUILTIN);
        assert_eq!(who(&both), ("Firefox, ZOOM VoiceEngine".into(), "microphone and camera"));
        let mut seq = times(&both, 10); // 0..18 s
        seq.extend(times(&dump(&firefox_cam(), BUILTIN), 10)); // the mic is free at 20 s, the camera is not
        seq.extend(times(&dump(&[], BUILTIN), 3)); // both free at 40 s
        assert_eq!(play(&mut Detector::default(), &seq), [(6000, Start), (44000, Stop)]);
    }

    #[test]
    fn shepetal_own_streams_never_start_or_hold_a_meeting() {
        // While a meeting records, shepetal holds the mic twice (Me.wav, a dictation) and the sink
        // monitor once (Others.wav). Counted, they would keep the recording on after the call,
        // forever. They are not even mic users: Me.wav and the dictation by pid, Others.wav as
        // a monitor.
        assert_eq!(meeting::mic_streams(&pw(&own(), BUILTIN), &[std::process::id()]), []);
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
        assert_eq!((Thresholds::default().prompt, Thresholds::parse("prompt=30").unwrap().prompt), (20000, 30000), "docs/re/meetings.md: 20 s card");
        for bad in ["startafter=5", "reacquire", "reacquire=-1", "reacquire=soon"] {
            assert!(Thresholds::parse(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn auto_record_is_opt_in() {
        // Pavel's rule: a detected meeting records only after one click, unless the user turned on
        // always-record. Only an explicit `true` records without asking.
        for off in ["", "{}", r#"{"shortcuts": {"paste_last": "shift+alt+z"}}"#, r#"{"meetings": {}}"#, r#"{"meetings": {"auto_record": false}}"#] {
            assert_eq!(auto_record(off), Ok(false), "{off}");
        }
        assert_eq!(auto_record(r#"{"retention": "keep", "meetings": {"auto_record": true}}"#), Ok(true));
        // A typo or a wrong type stops the daemon instead of guessing either way.
        for bad in [r#"{"meetings": {"auto_record": "yes"}}"#, r#"{"meetings": {"autorecord": true}}"#, r#"{"meetings": true}"#, "{"] {
            assert!(auto_record(bad).is_err(), "{bad}");
        }
        assert_eq!(auto_record(r#"{"meetings": {"auto_recrd": true}}"#), Err("unknown meetings setting \"auto_recrd\" (auto_record)".into()));

        let d = std::env::temp_dir().join(format!("shepetal-autorec-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        assert_eq!(load_auto_record(&d.join("missing.json")), Ok(false), "no config file: ask first");
        std::fs::write(d.join("config.json"), r#"{"meetings": {"auto_record": true}}"#).unwrap();
        assert_eq!(load_auto_record(&d.join("config.json")), Ok(true));
        assert!(load_auto_record(&d).unwrap_err().starts_with(&d.display().to_string()), "an unreadable config names the file");
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn the_prompt_has_one_record_button_and_expires_with_the_threshold() {
        let c = prompt_cmd("Firefox, ZOOM VoiceEngine", "microphone and camera", 20000);
        let args: Vec<_> = std::iter::once(c.get_program()).chain(c.get_args()).map(|a| a.to_string_lossy().into_owned()).collect();
        assert_eq!(args, ["notify-send", "--app-name=shepetal", "--action=record=Record", "--expire-time=20000", "Record this meeting?",
            "Firefox, ZOOM VoiceEngine is using the microphone and camera. Nothing is recorded unless you click Record."]);
        // The prompt names the apps when PipeWire or /proc does, and says what they use.
        let s = |mic: &[&str], cam: &[&str]| Snapshot {
            mic: mic.iter().map(|a| a.to_string()).collect(), cam: cam.iter().map(|a| a.to_string()).collect(), devices: vec![] };
        assert_eq!(who(&s(&[""], &[])), ("An app".into(), "microphone"));
        assert_eq!(who(&s(&[], &["zoom"])), ("zoom".into(), "camera"));
        assert_eq!(who(&s(&["", "Zoom"], &["Zoom"])), ("Zoom".into(), "microphone and camera"));
    }

    #[test]
    fn the_committed_pw_dump_fixture_is_a_meeting() {
        let d: Value = serde_json::from_str(include_str!("../fixtures/pw-dump-meeting.json")).unwrap();
        // Its shepetal recorder, pid 9001, is a child of this process in a fake /proc.
        let proc = std::env::temp_dir().join(format!("shepetal-fixproc-{}", std::process::id()));
        std::fs::create_dir_all(proc.join("9001")).unwrap();
        std::fs::write(proc.join("9001/status"), format!("Name:\tpw-record\nPPid:\t{}\n", std::process::id())).unwrap();
        let s = snapshot(&d, &proc);
        std::fs::remove_dir_all(&proc).unwrap();
        assert_eq!(s.mic, ["Firefox", "GNOME Sound Recorder", "ZOOM VoiceEngine"]);
        assert_eq!(s.cam, ["Firefox"]);
        assert_eq!(s.devices.len(), 2, "{:?}", s.devices);
        // Privacy: what is shown and logged is app names only. The fixture's camera stream has
        // a Meet tab title as its media.name.
        assert!(!format!("{s:?}{:?}", who(&s)).contains("Weekly sync"));
        assert_eq!(snapshot(&d, Path::new(NO_PROC)).mic.last().map(String::as_str), Some("shepetal"), "not our child: another app");
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

    /// One Zoom call (the first 12 pw-dump reads, 0.1 s apart) through the whole loop against
    /// fake pw-dump, pw-record, whisper-cli and notify-send. It runs in a child copy of this test
    /// binary, because the tests in main.rs swap PATH for their own fakes. The fake notify-send
    /// does `answer`: `record` (Record clicked), `dismiss`, or `ignore` (waits until SIGINT).
    /// `extra` adds thresholds. With `cam`, the call is Zoom holding /dev/video0 in a fake /proc
    /// instead of a PipeWire mic stream. Returns the fakes' dir in the parent, None in the child.
    fn call(test: &str, auto_record: bool, answer: &str, extra: &str, cam: bool) -> Option<PathBuf> {
        const HOME: &str = "SHEPETAL_TEST_MEETING_HOME";
        if let Ok(home) = std::env::var(HOME) {
            let home = PathBuf::from(home);
            // The call ends after read 12, so the meeting ends at about read 16.
            let t = Thresholds::parse(&format!("poll=0.1,start_after=0.3,min_session=0.5,reacquire=0.3,end_with_evidence=0.3,{extra}")).unwrap();
            let h = home.clone();
            let proc = home.parent().unwrap().join("proc");
            std::thread::spawn(move || run(&t, auto_record, &h, Path::new("/models/ggml.bin"), &proc));
            let reads = home.parent().unwrap().join("reads");
            for _ in 0..400 {
                std::thread::sleep(Duration::from_millis(50));
                // Done when the call is long over and every meeting recorded has its transcript.
                let n: u32 = std::fs::read_to_string(&reads).ok().and_then(|s| s.trim().parse().ok()).unwrap_or(0);
                let mut dirs = std::fs::read_dir(home.join("shepetal/meetings")).into_iter().flatten().flatten();
                if n >= 30 && dirs.all(|e| e.path().join("transcript.md").exists()) {
                    std::thread::sleep(Duration::from_millis(200)); // let the write finish
                    return None;
                }
            }
            panic!("not done within 20 s");
        }
        use std::os::unix::fs::PermissionsExt;
        let d = std::env::temp_dir().join(format!("shepetal-meet-{}-{}", test.rsplit(':').next().unwrap(), std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("bin")).unwrap();
        let (dd, call, idle) = (d.display(), pw(&[zoom()], BUILTIN), pw(&[], BUILTIN));
        let (on, off) = if cam {
            (format!("mkdir -p {dd}/proc/4242/fd; echo zoom > {dd}/proc/4242/comm; ln -sf /dev/video0 {dd}/proc/4242/fd/9; printf '%s' '{idle}'"),
             format!("rm -rf {dd}/proc/4242; printf '%s' '{idle}'"))
        } else {
            (format!("printf '%s' '{call}'"), format!("printf '%s' '{idle}'"))
        };
        let tools = [
            ("notify-send", format!("exec 2>/dev/null\necho \"$*\" >> {dd}/prompt.args\ncase {answer} in\n\
                record) sleep 0.2; echo record ;;\n\
                dismiss) sleep 0.2 ;;\n\
                *) trap 'echo \"closed after read $(cat {dd}/reads)\" >> {dd}/prompt.log; exit 0' INT\n\
                   i=0; while [ $i -lt 3000 ]; do sleep 0.01; i=$((i+1)); done ;;\nesac\n")),
            // The call holds the mic (or the camera) for the first 12 reads, then it is gone.
            ("pw-dump", format!("n=$(cat {dd}/reads 2>/dev/null || echo 0); echo $((n+1)) > {dd}/reads\n\
                if [ $n -lt 12 ]; then {on}; else {off}; fi\n")),
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
            .args([test, "--exact", "--nocapture"])
            .env("PATH", format!("{dd}/bin:{}", std::env::var("PATH").unwrap_or_default()))
            .env(HOME, d.join("home"))
            .output().unwrap();
        let log = String::from_utf8_lossy(&out.stderr).into_owned() + &String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "{log}");
        Some(d)
    }

    fn read(p: PathBuf) -> String {
        std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
    }

    /// Nothing was recorded: no recorder ever ran and no meeting folder was even made.
    fn nothing_recorded(d: &Path) {
        assert!(!d.join("rec.args").exists(), "a recorder ran: {}", std::fs::read_to_string(d.join("rec.args")).unwrap_or_default());
        assert!(!d.join("home/shepetal/meetings").exists());
        std::fs::remove_dir_all(d).unwrap();
    }

    /// The call was recorded, stopped and transcribed, with `app` in its header.
    fn recorded(d: &Path, app: &str) {
        use std::os::unix::fs::PermissionsExt;
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
        assert_eq!(read("transcript.md"), format!("# Meeting\n\n- Apps: {app}\n- Audio: Me.wav (microphone), Others.wav (system audio)\n\n\
            [00:00:01] Me: Hello from me.\n\n[00:00:01] Others: Hi from them.\n"));
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!([mode(dir), mode(&dir.join(ME)), mode(&dir.join("transcript.md"))], [0o700, 0o600, 0o600]);
        std::fs::remove_dir_all(d).unwrap();
    }

    /// The pw-dump read after which the fake notify-send got SIGINT (the prompt was withdrawn).
    fn closed_after(d: &Path) -> u32 {
        let log = read(d.join("prompt.log"));
        log.trim().strip_prefix("closed after read ").and_then(|n| n.parse().ok()).unwrap_or_else(|| panic!("{log}"))
    }

    #[test]
    fn a_meeting_records_only_after_record_is_clicked() {
        let Some(d) = call("meeting_rec::tests::a_meeting_records_only_after_record_is_clicked", false, "record", "", false) else { return };
        let asked = read(d.join("prompt.args"));
        assert_eq!(asked.lines().count(), 1, "one prompt per meeting: {asked}");
        assert!(asked.contains("--action=record=Record") && asked.contains("ZOOM VoiceEngine is using the microphone."), "{asked}");
        recorded(&d, "ZOOM VoiceEngine");
    }

    #[test]
    fn a_camera_alone_is_offered_and_records_after_the_click() {
        // Zoom opens /dev/video0 itself, past PipeWire: only the /proc scan sees it.
        let Some(d) = call("meeting_rec::tests::a_camera_alone_is_offered_and_records_after_the_click", false, "record", "", true) else { return };
        let asked = read(d.join("prompt.args"));
        assert_eq!(asked.lines().count(), 1, "one prompt per meeting: {asked}");
        assert!(asked.contains("zoom is using the camera."), "{asked}");
        recorded(&d, "zoom");
    }

    #[test]
    fn a_dismissed_prompt_records_nothing_for_that_meeting() {
        let Some(d) = call("meeting_rec::tests::a_dismissed_prompt_records_nothing_for_that_meeting", false, "dismiss", "", false) else { return };
        assert_eq!(read(d.join("prompt.args")).lines().count(), 1, "not asked again in the same meeting");
        nothing_recorded(&d);
    }

    #[test]
    fn an_unanswered_prompt_is_withdrawn_and_records_nothing() {
        // The call lasts 12 reads. A 0.5 s prompt shown at about read 3 must go well before that.
        let Some(d) = call("meeting_rec::tests::an_unanswered_prompt_is_withdrawn_and_records_nothing", false, "ignore", "prompt=0.5", false) else { return };
        assert!(closed_after(&d) < 12, "withdrawn by the timeout, not by the end of the call");
        nothing_recorded(&d);
    }

    #[test]
    fn the_prompt_is_withdrawn_when_the_call_ends_first() {
        let Some(d) = call("meeting_rec::tests::the_prompt_is_withdrawn_when_the_call_ends_first", false, "ignore", "prompt=60", false) else { return };
        assert!(closed_after(&d) >= 12, "withdrawn when the call ended");
        nothing_recorded(&d);
    }

    #[test]
    fn auto_record_records_without_asking() {
        let Some(d) = call("meeting_rec::tests::auto_record_records_without_asking", true, "record", "", false) else { return };
        assert!(!d.join("prompt.args").exists(), "no prompt with meetings.auto_record");
        recorded(&d, "ZOOM VoiceEngine");
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
