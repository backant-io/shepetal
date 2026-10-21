//! Mic selection and mic health for the daemon (docs/re/dictation-input.md, sections on mic
//! selection and the dead-mic check).
//!
//! - Input sources come from `pw-dump` JSON, else `pactl -f json list sources`.
//! - The user ranks them in `~/.config/shepetal/config.toml`:
//!
//!   ```toml
//!   [mic]
//!   # Best first. Each entry matches a source's name or description, case-insensitive substring.
//!   prefer = ["Jabra", "Yeti"]
//!   ```
//!
//!   Sources no entry matches come after, in this order: the desktop's default source, then
//!   external ones (USB, Bluetooth), then built-in. With the lid closed the built-in mic goes
//!   last of all, so it is used only when nothing else is plugged in.
//! - The pick is made again at every record start from a fresh list, so a mic plugged in or
//!   removed between dictations is picked up without a restart. During a dictation the source is
//!   never swapped (the clip would change mic mid-sentence); if it disappears the recorder is
//!   stopped, what was said so far is kept and transcribed, and a "mic disconnected" alert shows.
//! - Alerts (no audio, mic disconnected, mic unreadable, no PipeWire/PulseAudio) go to
//!   `notify-send` and as an `error <text>` line to the 🤫 hint sink, at most once per kind per
//!   [`ALERT_EVERY`]. Advice (a Bluetooth headset mic, the lid closed on the only mic) goes the
//!   same way as a `hint <text>` line, once per daemon run.

use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const RATE: u32 = 16_000;
/// "no audio" fires once the samples have been exactly zero for longer than this. Quiet speech
/// is never all zero; a run of pure zeros is a dead mic, a hardware mute or a driver bug.
pub const NO_AUDIO_AFTER: Duration = Duration::from_secs(5);
/// "mic unreadable" fires, and the recorder is stopped, once no samples arrived for this long.
pub const NO_FRAMES_AFTER: Duration = Duration::from_secs(5);
/// The same alert kind is shown at most once per this window.
pub const ALERT_EVERY: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, PartialEq)]
pub struct Source {
    /// `node.name`: what `pw-record --target` and `parecord --device` take.
    pub name: String,
    pub description: String,
    /// `device.bus`: `pci`, `usb`, `bluetooth`, ... (empty if unknown).
    pub bus: String,
    /// The laptop's own mic: `device.form-factor` internal, or on the pci/platform bus.
    pub builtin: bool,
    pub is_default: bool,
}

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}

fn builtin(bus: &str, form_factor: &str) -> bool {
    form_factor == "internal" || (form_factor.is_empty() && matches!(bus, "pci" | "platform" | "isa"))
}

/// Hardware input sources in a `pw-dump`. Virtual sources (echo cancel, loopbacks) and sink
/// monitors are not mics and are left out.
pub fn from_pw_dump(dump: &Value) -> Vec<Source> {
    let Some(objs) = dump.as_array() else { return vec![] };
    let default = objs.iter()
        .filter(|o| s(o, "type") == "PipeWire:Interface:Metadata")
        .flat_map(|o| o["metadata"].as_array().into_iter().flatten())
        .find(|m| s(m, "key") == "default.audio.source")
        .map(|m| match &m["value"] {
            // pw-dump prints the value as JSON; older versions as a JSON string.
            Value::String(j) => serde_json::from_str::<Value>(j).ok().map(|v| s(&v, "name").to_string()).unwrap_or_default(),
            v => s(v, "name").to_string(),
        })
        .unwrap_or_default();
    let devices: HashMap<u64, &Value> = objs.iter()
        .filter(|o| s(o, "type") == "PipeWire:Interface:Device")
        .filter_map(|o| Some((o["id"].as_u64()?, &o["info"]["props"])))
        .collect();
    objs.iter()
        .filter(|o| s(o, "type") == "PipeWire:Interface:Node")
        .map(|o| &o["info"]["props"])
        .filter(|p| s(p, "media.class") == "Audio/Source" && !s(p, "node.name").ends_with(".monitor"))
        .map(|p| {
            let dev = p["device.id"].as_u64().and_then(|id| devices.get(&id)).copied().unwrap_or(&Value::Null);
            let pick = |k: &str| [s(p, k), s(dev, k)].into_iter().find(|v| !v.is_empty()).unwrap_or("").to_string();
            let (bus, ff) = (pick("device.bus"), pick("device.form-factor"));
            let name = s(p, "node.name").to_string();
            Source { builtin: builtin(&bus, &ff), is_default: name == default, description: s(p, "node.description").to_string(), bus, name }
        })
        .collect()
}

/// Sources from `pactl -f json list sources` (PulseAudio 16+, pipewire-pulse), with `default`
/// from `pactl get-default-source`. Monitors are left out.
pub fn from_pactl(list: &Value, default: &str) -> Vec<Source> {
    list.as_array().into_iter().flatten()
        .filter(|o| s(&o["properties"], "device.class") != "monitor" && !s(o, "name").ends_with(".monitor"))
        .map(|o| {
            let p = &o["properties"];
            let (bus, ff) = (s(p, "device.bus").to_string(), s(p, "device.form_factor"));
            Source {
                name: s(o, "name").to_string(),
                description: s(o, "description").to_string(),
                builtin: builtin(&bus, ff),
                is_default: s(o, "name") == default,
                bus,
            }
        })
        .collect()
}

/// The ranked list from `[mic] prefer = [...]` in config.toml. Only that key is read; a missing
/// file or key is an empty list. The array may span lines; `#` starts a comment outside quotes.
pub fn parse_prefs(toml: &str) -> Vec<String> {
    let mut section = String::new();
    let mut lines = toml.lines();
    while let Some(line) = lines.next() {
        let line = strip_comment(line);
        let t = line.trim();
        if t.starts_with('[') {
            section = t.trim_matches(|c| c == '[' || c == ']').trim().to_string();
            continue;
        }
        let Some((k, v)) = t.split_once('=') else { continue };
        if section != "mic" || k.trim() != "prefer" {
            continue;
        }
        let mut v = v.to_string();
        while !v.contains(']') {
            let Some(next) = lines.next() else { break };
            v.push_str(&strip_comment(next));
        }
        return quoted(&v);
    }
    vec![]
}

fn strip_comment(line: &str) -> String {
    let mut in_str = false;
    line.chars().take_while(|&c| {
        if c == '"' { in_str = !in_str; }
        in_str || c != '#'
    }).collect()
}

fn quoted(v: &str) -> Vec<String> {
    v.split('"').skip(1).step_by(2).map(str::trim).filter(|x| !x.is_empty()).map(String::from).collect()
}

/// `$XDG_CONFIG_HOME/shepetal/config.toml`, else `~/.config/shepetal/config.toml`. A relative
/// XDG_CONFIG_HOME is ignored, as the XDG spec says.
pub fn config_path(xdg: Option<&str>, home: &str) -> PathBuf {
    match xdg {
        Some(d) if d.starts_with('/') => PathBuf::from(d),
        _ => PathBuf::from(home).join(".config"),
    }.join("shepetal/config.toml")
}

/// Whether every lid under `/proc/acpi/button/lid/*/state` says closed. No lid (a desktop) or
/// an unreadable one is open: a mic is never skipped on a guess.
pub fn lid_closed(acpi_lid: &Path) -> bool {
    let states: Vec<String> = std::fs::read_dir(acpi_lid).into_iter().flatten().flatten()
        .filter_map(|e| std::fs::read_to_string(e.path().join("state")).ok())
        .collect();
    !states.is_empty() && states.iter().all(|st| st.contains("closed"))
}

/// The user's rank for `src`: the index of the first preference it matches.
fn pref_rank(src: &Source, prefs: &[String]) -> Option<usize> {
    let (n, d) = (src.name.to_lowercase(), src.description.to_lowercase());
    prefs.iter().position(|p| {
        let p = p.to_lowercase();
        !p.is_empty() && (n.contains(&p) || d.contains(&p))
    })
}

/// All sources, best first. See the module docs for the order.
pub fn rank(sources: &[Source], prefs: &[String], lid_closed: bool) -> Vec<Source> {
    let mut v = sources.to_vec();
    v.sort_by_key(|src| {
        let clamshell = lid_closed && src.builtin;
        let tier = match pref_rank(src, prefs) {
            Some(i) => i,
            None if src.is_default => prefs.len(),
            None if !src.builtin => prefs.len() + 1,
            None => prefs.len() + 2,
        };
        (clamshell, tier, src.name.clone())
    });
    v
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Reason {
    /// The mic used last time is gone.
    Disconnect,
    /// A mic ranked higher than the last one appeared.
    RankUp,
}

/// Remembers the last pick so a change between dictations is reported as a switch.
#[derive(Debug, Default)]
pub struct Picker {
    last: Option<String>,
}

impl Picker {
    /// The best source now, and why it differs from last time (None on the first pick or
    /// when it is the same mic).
    pub fn pick(&mut self, sources: &[Source], prefs: &[String], lid_closed: bool) -> Option<(Source, Option<Reason>)> {
        let best = rank(sources, prefs, lid_closed).into_iter().next()?;
        let reason = match self.last.as_deref() {
            Some(last) if last == best.name => None,
            Some(last) if sources.iter().any(|x| x.name == last) => Some(Reason::RankUp),
            Some(_) => Some(Reason::Disconnect),
            None => None,
        };
        self.last = Some(best.name.clone());
        Some((best, reason))
    }
}

/// Counts consecutive all-zero samples and fires once per run longer than [`NO_AUDIO_AFTER`].
#[derive(Debug, Default)]
pub struct ZeroRun {
    zeros: u64,
    fired: bool,
}

impl ZeroRun {
    /// Feed the next samples; true once, when the zero run passes the limit.
    pub fn feed(&mut self, samples: &[i16]) -> bool {
        let limit = NO_AUDIO_AFTER.as_secs() * RATE as u64;
        let mut fire = false;
        for &x in samples {
            if x != 0 {
                (self.zeros, self.fired) = (0, false);
                continue;
            }
            self.zeros += 1;
            if self.zeros > limit && !self.fired {
                (self.fired, fire) = (true, true);
            }
        }
        fire
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Alert {
    NoAudio(String),
    Disconnected(String),
    /// The recorder runs but no samples came for [`NO_FRAMES_AFTER`]: the device stopped
    /// delivering, or the file cannot be read.
    Unreadable(String),
    NoAudioServer,
    /// Advice: a Bluetooth headset mic records in the headset's call mode.
    Bluetooth(String),
    /// Advice: the lid is closed and the built-in mic is the only one.
    Clamshell,
}

impl Alert {
    pub fn text(&self) -> String {
        match self {
            Alert::NoAudio(m) => format!("No sound from {m}: it sends only silence. Check that it is not muted, or rank another one (shepetal mics)."),
            Alert::Disconnected(m) => format!("Mic disconnected: {m}. Dictation stopped; what you said before is kept."),
            Alert::Unreadable(m) => format!("Cannot read {m}: no sound arrived for 5 s. Dictation stopped; what you said before is kept. Replug the mic or rank another one (shepetal mics)."),
            Alert::NoAudioServer => "No PipeWire or PulseAudio found, so shepetal cannot record. Install pipewire-bin (or pulseaudio-utils) and start the sound server.".into(),
            Alert::Bluetooth(m) => format!("{m} is a Bluetooth headset: while it records, it switches to its low-quality call mode, so words get lost and its sound gets worse. A built-in or wired mic transcribes better: rank one first (shepetal mics)."),
            Alert::Clamshell => "The lid is closed and the built-in mic is the only one, so it may sound muffled. Open the lid or plug in a mic.".into(),
        }
    }

    /// The few words next to 🤫, which stays tiny; the notification has the whole text.
    pub fn short(&self) -> &'static str {
        match self {
            Alert::NoAudio(_) => "No sound from the mic",
            Alert::Disconnected(_) => "Mic disconnected",
            Alert::Unreadable(_) => "Cannot read the mic",
            Alert::NoAudioServer => "No PipeWire or PulseAudio",
            Alert::Bluetooth(_) => "Bluetooth mic: lower quality",
            Alert::Clamshell => "Lid closed: mic muffled",
        }
    }

    /// Advice shows as a hint next to 🤫, not as an error.
    pub fn advice(&self) -> bool {
        matches!(self, Alert::Bluetooth(_) | Alert::Clamshell)
    }

    fn kind(&self) -> u8 {
        match self {
            Alert::NoAudio(_) => 0,
            Alert::Disconnected(_) => 1,
            Alert::NoAudioServer => 2,
            Alert::Unreadable(_) => 3,
            Alert::Bluetooth(_) => 4,
            Alert::Clamshell => 5,
        }
    }
}

/// Lets each alert kind through at most once per `every`.
#[derive(Debug)]
pub struct RateLimit {
    every: Duration,
    last: HashMap<u8, Instant>,
}

impl RateLimit {
    pub fn new(every: Duration) -> RateLimit {
        RateLimit { every, last: HashMap::new() }
    }

    pub fn allow(&mut self, a: &Alert, now: Instant) -> bool {
        match self.last.get(&a.kind()) {
            Some(&t) if now.saturating_duration_since(t) < self.every => false,
            _ => {
                self.last.insert(a.kind(), now);
                true
            }
        }
    }
}

type Sink = Box<dyn Fn(&str) + Send>;

/// Where `hint <text>` and `error <text>` lines for the 🤫 overlay go (the daemon's indicator
/// socket). They always go to stderr too, as the daemon's other hints do.
static HINTS: Mutex<Option<Sink>> = Mutex::new(None);
static LIMIT: Mutex<Option<RateLimit>> = Mutex::new(None);
static PICKER: Mutex<Picker> = Mutex::new(Picker { last: None });
static NOTICES: Mutex<Notices> = Mutex::new(Notices { bluetooth: false, clamshell: false });

/// Advice about the mic a dictation opens, each kind once per daemon run.
#[derive(Debug, Default)]
pub struct Notices {
    bluetooth: bool,
    clamshell: bool,
}

impl Notices {
    /// `src` was picked from `sources`. A Bluetooth mic is worth a word only when another mic
    /// could take its place (as the Mac's `MicNotices`); the built-in mic with the lid closed
    /// only when it is the one recording, so nothing else is plugged in.
    pub fn opening(&mut self, src: &Source, sources: &[Source], lid_closed: bool) -> Option<Alert> {
        let usable = |x: &&Source| x.name != src.name && x.bus != "bluetooth" && !(lid_closed && x.builtin);
        if src.bus == "bluetooth" && !self.bluetooth && sources.iter().any(|x| usable(&x)) {
            self.bluetooth = true;
            return Some(Alert::Bluetooth(src.description.clone()));
        }
        if lid_closed && src.builtin && !self.clamshell {
            self.clamshell = true;
            return Some(Alert::Clamshell);
        }
        None
    }
}

/// Send the overlay lines somewhere else (the indicator socket).
pub fn set_hint_sink(f: impl Fn(&str) + Send + 'static) {
    *HINTS.lock().unwrap() = Some(Box::new(f));
}

fn hint_line(line: &str) {
    eprintln!("shepetal: {}", line.replacen(' ', ": ", 1));
    if let Some(f) = HINTS.lock().unwrap().as_ref() {
        f(line);
    }
}

/// Show `a` as a desktop notification and next to 🤫, unless the same kind was shown less than
/// [`ALERT_EVERY`] ago. Returns whether it was shown.
pub fn alert(a: Alert) -> bool {
    // Our own fixed wording plus a device description, not dictated text.
    show(a, |text| {
        let _ = Command::new("notify-send").args(["-a", "shepetal", "-i", "audio-input-microphone", "shepetal", text]).status();
    })
}

fn show(a: Alert, notify: impl Fn(&str)) -> bool {
    let shown = LIMIT.lock().unwrap().get_or_insert_with(|| RateLimit::new(ALERT_EVERY)).allow(&a, Instant::now());
    if shown {
        let text = a.text();
        eprintln!("shepetal: {text}");
        if let Some(f) = HINTS.lock().unwrap().as_ref() {
            f(&format!("{} {}", if a.advice() { "hint" } else { "error" }, a.short()));
        }
        notify(&text);
    }
    shown
}

/// Run a command and return its stdout, or None if it is missing or fails.
fn output(cmd: &str, args: &[&str]) -> Option<String> {
    let o = Command::new(cmd).args(args).output().ok()?;
    o.status.success().then(|| String::from_utf8_lossy(&o.stdout).into_owned())
}

/// The input sources now, from PipeWire, else PulseAudio. Err when neither answers.
pub fn list() -> Result<Vec<Source>, Alert> {
    if let Some(dump) = output("pw-dump", &[]).and_then(|j| serde_json::from_str::<Value>(&j).ok()) {
        return Ok(from_pw_dump(&dump));
    }
    let default = output("pactl", &["get-default-source"]).unwrap_or_default();
    output("pactl", &["-f", "json", "list", "sources"])
        .and_then(|j| serde_json::from_str::<Value>(&j).ok())
        .map(|v| from_pactl(&v, default.trim()))
        .ok_or(Alert::NoAudioServer)
}

/// The user's ranked list from config.toml.
pub fn prefs() -> Vec<String> {
    let path = config_path(std::env::var("XDG_CONFIG_HOME").ok().as_deref(), &std::env::var("HOME").unwrap_or_default());
    parse_prefs(&std::fs::read_to_string(path).unwrap_or_default())
}

pub const ACPI_LID: &str = "/proc/acpi/button/lid";

/// The mic to record from at a record start, or None to leave it to the sound server's default
/// (no sources listed). Shows the no-server alert and a hint when the mic changed.
pub fn pick_for_recording() -> Option<Source> {
    let sources = list().map_err(alert).ok()?;
    let lid = lid_closed(Path::new(ACPI_LID));
    let (src, reason) = PICKER.lock().unwrap().pick(&sources, &prefs(), lid)?;
    if let Some(r) = reason {
        let why = if r == Reason::Disconnect { "the last one is gone" } else { "ranked higher" };
        hint_line(&format!("hint Mic: {} ({why})", src.description));
    }
    if let Some(a) = NOTICES.lock().unwrap().opening(&src, &sources, lid) {
        alert(a);
    }
    Some(src)
}

/// Byte offset of the samples in a WAV, from its RIFF chunks; None until the header is written.
pub fn data_offset(b: &[u8]) -> Option<usize> {
    if b.len() < 12 || &b[0..4] != b"RIFF" || &b[8..12] != b"WAVE" {
        return None;
    }
    let mut i = 12;
    while i + 8 <= b.len() {
        if &b[i..i + 4] == b"data" {
            return Some(i + 8);
        }
        let n = u32::from_le_bytes(b[i + 4..i + 8].try_into().ok()?) as usize;
        i += 8 + n + (n & 1);
    }
    None
}

/// What [`watch`] does each [`WATCH_EVERY`]: one step over a growing WAV and the source list.
#[derive(Debug)]
pub struct Health {
    mic: Option<Source>,
    read: usize,
    odd: Option<u8>,
    zeros: ZeroRun,
    /// Steps in a row without a new sample.
    stalled: u32,
}

#[derive(Debug, PartialEq)]
pub enum Verdict {
    Ok,
    Alert(Alert),
    /// The mic is gone: alert, and stop the recorder.
    Stop(Alert),
}

impl Health {
    pub fn new(mic: Option<Source>) -> Health {
        Health { mic, read: 0, odd: None, zeros: ZeroRun::default(), stalled: 0 }
    }

    /// One [`WATCH_EVERY`] step. `wav` is the whole file so far (empty when it cannot be read);
    /// `sources` the current list (None: not polled this time).
    pub fn step(&mut self, wav: &[u8], sources: Option<&[Source]>) -> Verdict {
        if let (Some(mic), Some(now)) = (&self.mic, sources) {
            if !now.iter().any(|x| x.name == mic.name) {
                return Verdict::Stop(Alert::Disconnected(mic.description.clone()));
            }
        }
        let grew = data_offset(wav).is_some_and(|start| wav.len() - start > self.read);
        self.stalled = if grew { 0 } else { self.stalled + 1 };
        if self.stalled as u128 * WATCH_EVERY.as_millis() >= NO_FRAMES_AFTER.as_millis() {
            return Verdict::Stop(Alert::Unreadable(self.name()));
        }
        let Some(start) = data_offset(wav) else { return Verdict::Ok };
        let mut bytes: Vec<u8> = self.odd.take().into_iter().collect();
        bytes.extend_from_slice(&wav[(start + self.read).min(wav.len())..]);
        self.read = wav.len().saturating_sub(start);
        if bytes.len() % 2 == 1 {
            self.odd = bytes.pop();
        }
        let samples: Vec<i16> = bytes.chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]])).collect();
        if self.zeros.feed(&samples) {
            return Verdict::Alert(Alert::NoAudio(self.name()));
        }
        Verdict::Ok
    }

    fn name(&self) -> String {
        self.mic.as_ref().map_or("the mic".to_string(), |m| m.description.clone())
    }
}

pub const WATCH_EVERY: Duration = Duration::from_millis(500);
/// The source list is polled this often while recording (one pw-dump run each time).
const POLL_EVERY: u32 = 4;

/// Whether `pid` is still the recorder (and not a reused pid after it was reaped).
fn alive(pid: u32, comm: &str) -> bool {
    std::fs::read_to_string(format!("/proc/{pid}/comm")).is_ok_and(|c| c.trim() == comm)
}

/// Watch a running recorder (`pid`, process name `comm`) writing `wav` from `mic`, until it
/// exits: alert on an all-zero signal, and stop it with SIGINT (so the WAV stays valid) when
/// the mic disappears or sends nothing for [`NO_FRAMES_AFTER`].
pub fn watch(pid: u32, comm: &'static str, wav: PathBuf, mic: Option<Source>) {
    std::thread::spawn(move || {
        let mut h = Health::new(mic);
        let mut n = 0u32;
        loop {
            std::thread::sleep(WATCH_EVERY);
            // Checked after the sleep: once the recorder is reaped its pid may be another process.
            if !alive(pid, comm) {
                return;
            }
            n += 1;
            let sources = (n % POLL_EVERY == 0).then(list).and_then(Result::ok);
            let bytes = std::fs::read(&wav).unwrap_or_default();
            match h.step(&bytes, sources.as_deref()) {
                Verdict::Ok => {}
                Verdict::Alert(a) => {
                    alert(a);
                }
                Verdict::Stop(a) => {
                    alert(a);
                    // The shell's builtin kill, as the daemon's stop(): Debian slim has no /usr/bin/kill.
                    let _ = Command::new("sh").args(["-c", "kill -INT \"$0\"", &pid.to_string()]).status();
                    return;
                }
            }
        }
    });
}

/// `shepetal mics`: every source, best first, with why it sits where it does.
pub fn describe(sources: &[Source], prefs: &[String], lid_closed: bool) -> String {
    let mut out = String::new();
    if sources.is_empty() {
        out.push_str("no input sources found\n");
    }
    for (i, src) in rank(sources, prefs, lid_closed).iter().enumerate() {
        let mut why = vec![];
        if let Some(p) = pref_rank(src, prefs) {
            why.push(format!("preference #{} \"{}\"", p + 1, prefs[p]));
        }
        if src.is_default {
            why.push("desktop default".into());
        }
        if src.builtin {
            why.push(if lid_closed { "built-in, lid closed: last resort".into() } else { "built-in".to_string() });
        }
        let bus = if src.bus.is_empty() { "?" } else { &src.bus };
        out.push_str(&format!("{:>2}. {}{} [{bus}] {}{}\n", i + 1, if i == 0 { "* " } else { "  " }, src.description, src.name,
            if why.is_empty() { String::new() } else { format!(" ({})", why.join(", ")) }));
    }
    out
}

/// The recorder flags that record from `src`; none leaves it to the sound server's default.
pub fn target_args(recorder: &str, src: Option<&Source>) -> Vec<String> {
    match src {
        None => vec![],
        Some(m) if recorder == "parecord" => vec![format!("--device={}", m.name)],
        Some(m) => vec!["--target".into(), m.name.clone()],
    }
}

/// `shepetal mics [--pw-dump FILE]`.
pub fn mics(dump_file: Option<&String>) -> Result<(), String> {
    let sources = match dump_file {
        Some(f) => {
            let j = std::fs::read_to_string(f).map_err(|e| format!("{f}: {e}"))?;
            from_pw_dump(&serde_json::from_str(&j).map_err(|e| format!("pw-dump json: {e}"))?)
        }
        None => list().map_err(|a| a.text())?,
    };
    let lid = lid_closed(Path::new(ACPI_LID));
    print!("{}", describe(&sources, &prefs(), lid));
    let home = std::env::var("HOME").unwrap_or_default();
    println!("ranking: [mic] prefer = [...] in {}", config_path(std::env::var("XDG_CONFIG_HOME").ok().as_deref(), &home).display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> Value {
        let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures").join(name);
        serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
    }

    fn names(v: &[Source]) -> Vec<&str> {
        v.iter().map(|x| x.description.as_str()).collect()
    }

    const BUILTIN: &str = "Built-in Audio Analog Stereo";
    const YETI: &str = "Yeti Stereo Microphone Analog Stereo";
    const WEBCAM: &str = "HD Webcam C615 Analog Stereo";
    const JABRA: &str = "Jabra Evolve2 65";

    #[test]
    fn pw_dump_lists_hardware_sources_only() {
        let src = from_pw_dump(&fixture("pw-dump-mics.json"));
        assert_eq!(names(&src), [BUILTIN, YETI, WEBCAM, JABRA], "no sink, monitor, echo-cancel or stream");
        let b = &src[0];
        assert!(b.builtin && b.bus == "pci");
        assert!(!src[1].builtin && src[1].bus == "usb", "bus comes from the Device object");
        assert_eq!(src[3].bus, "bluetooth");
        assert!(src[2].is_default && src.iter().filter(|x| x.is_default).count() == 1);
    }

    #[test]
    fn pactl_json_skips_monitors() {
        let src = from_pactl(&fixture("pactl-sources.json"), "alsa_input.pci-0000_00_1f.3.analog-stereo");
        assert_eq!(names(&src), [BUILTIN, YETI]);
        assert!(src[0].builtin && src[0].is_default && !src[1].builtin);
    }

    #[test]
    fn ranking_follows_the_users_list_then_default_external_builtin() {
        let src = from_pw_dump(&fixture("pw-dump-mics.json"));
        let prefs = parse_prefs("[mic]\nprefer = [\"jabra\", # headset first\n  \"Yeti\"]\n");
        assert_eq!(prefs, ["jabra", "Yeti"]);
        assert_eq!(names(&rank(&src, &prefs, false)), [JABRA, YETI, WEBCAM, BUILTIN]);
        // No list: the desktop default, then external (by node name), then the built-in mic.
        assert_eq!(names(&rank(&src, &[], false)), [WEBCAM, YETI, JABRA, BUILTIN]);
        // The desktop default comes before other external mics whatever its name.
        let mut jabra_default = src.clone();
        jabra_default.iter_mut().for_each(|x| x.is_default = x.description == JABRA);
        assert_eq!(names(&rank(&jabra_default, &[], false)), [JABRA, WEBCAM, YETI, BUILTIN]);
        // The order of the user's list decides, not the order of the devices.
        let rev = vec!["yeti".to_string(), "jabra".to_string()];
        assert_eq!(names(&rank(&src, &rev, false))[..2], [YETI, JABRA]);
        // A preference matches the node name too.
        let by_node = vec!["alsa_input.pci".to_string()];
        assert_eq!(rank(&src, &by_node, false)[0].description, BUILTIN);
    }

    #[test]
    fn lid_closed_puts_the_builtin_mic_last_even_when_preferred() {
        let src = from_pw_dump(&fixture("pw-dump-mics.json"));
        let prefs = vec!["Built-in".to_string(), "Yeti".to_string()];
        assert_eq!(rank(&src, &prefs, false)[0].description, BUILTIN);
        let closed = rank(&src, &prefs, true);
        assert_eq!(closed[0].description, YETI);
        assert_eq!(closed.last().unwrap().description, BUILTIN);
        // Nothing else plugged in: the built-in mic is still used.
        let only = vec![src[0].clone()];
        assert_eq!(rank(&only, &prefs, true)[0].description, BUILTIN);
    }

    #[test]
    fn lid_state_from_acpi() {
        let dir = std::env::temp_dir().join(format!("shepetal-lid-{}", std::process::id()));
        let lid = dir.join("LID0");
        std::fs::create_dir_all(&lid).unwrap();
        assert!(!lid_closed(&dir), "a lid with no state file is not closed");
        std::fs::write(lid.join("state"), "state:      open\n").unwrap();
        assert!(!lid_closed(&dir));
        std::fs::write(lid.join("state"), "state:      closed\n").unwrap();
        assert!(lid_closed(&dir));
        assert!(!lid_closed(&dir.join("missing")), "a desktop has no lid");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn hot_plug_switches_at_the_next_record_start() {
        let all = from_pw_dump(&fixture("pw-dump-mics.json"));
        let unplugged = from_pw_dump(&fixture("pw-dump-mics-unplugged.json"));
        assert!(!names(&unplugged).contains(&YETI));
        let prefs = vec!["Yeti".to_string()];
        let mut p = Picker::default();
        let first = p.pick(&unplugged, &prefs, false).unwrap();
        assert_eq!((first.0.description.as_str(), first.1), (WEBCAM, None), "the default, first pick is no switch");
        assert_eq!(p.pick(&unplugged, &prefs, false).unwrap().1, None, "same mic again");
        let plugged = p.pick(&all, &prefs, false).unwrap();
        assert_eq!((plugged.0.description.as_str(), plugged.1), (YETI, Some(Reason::RankUp)));
        let gone = p.pick(&unplugged, &prefs, false).unwrap();
        assert_eq!((gone.0.description.as_str(), gone.1), (WEBCAM, Some(Reason::Disconnect)));
        assert!(p.pick(&[], &prefs, false).is_none());
    }

    fn wav(samples: &[i16]) -> Vec<u8> {
        // A LIST chunk before data, as some writers add: the samples must be found after it.
        let mut b = b"RIFF\0\0\0\0WAVEfmt \x10\0\0\0".to_vec();
        b.extend_from_slice(&[1, 0, 1, 0, 0x80, 0x3e, 0, 0, 0, 0x7d, 0, 0, 2, 0, 16, 0]);
        b.extend_from_slice(b"LIST\x03\0\0\0abc\0");
        b.extend_from_slice(b"data\0\0\0\0");
        samples.iter().for_each(|x| b.extend_from_slice(&x.to_le_bytes()));
        b
    }

    #[test]
    fn wav_samples_start_after_the_data_chunk() {
        let w = wav(&[7]);
        assert_eq!(data_offset(&w), Some(w.len() - 2));
        assert_eq!(data_offset(&w[..20]), None, "header not written yet");
        assert_eq!(data_offset(b"not a wav at all"), None);
    }

    #[test]
    fn no_audio_only_after_more_than_5_s_of_exact_zeros() {
        let five_s = 5 * RATE as usize;
        let mut z = ZeroRun::default();
        assert!(!z.feed(&vec![0; five_s]), "exactly 5 s is not more than 5 s");
        assert!(z.feed(&[0]), "one more zero sample crosses the line");
        assert!(!z.feed(&vec![0; five_s]), "fires once per run");
        assert!(!z.feed(&[1]));
        assert!(!z.feed(&vec![0; five_s]), "a sample breaks the run");
        assert!(z.feed(&[0]), "a new run fires again");

        // Very quiet audio (±1) is not silence from a dead mic.
        let mut quiet = ZeroRun::default();
        let hush: Vec<i16> = (0..10 * RATE as i32).map(|i| if i % 1000 == 0 { 1 } else { 0 }).collect();
        assert!(!quiet.feed(&hush));
    }

    #[test]
    fn health_reads_a_growing_wav_and_catches_a_dead_mic() {
        let mic = from_pw_dump(&fixture("pw-dump-mics.json"))[1].clone();
        let mut h = Health::new(Some(mic));
        let full = wav(&vec![0; 6 * RATE as usize]);
        let header = data_offset(&full).unwrap();
        // The recorder writes in pieces, also splitting a sample in two.
        let cuts = [header - 3, header + 1, header + 2 * RATE as usize * 3 + 1, header + 2 * RATE as usize * 5 + 1, full.len()];
        let verdicts: Vec<_> = cuts.iter().map(|&c| h.step(&full[..c], None)).collect();
        assert_eq!(verdicts[..4], [Verdict::Ok, Verdict::Ok, Verdict::Ok, Verdict::Ok]);
        assert_eq!(verdicts[4], Verdict::Alert(Alert::NoAudio(YETI.into())));

        // A recorder write that ends mid-sample: the first byte of the one non-zero sample
        // must be carried to the next read, not dropped.
        let mut s = vec![0i16; 6 * RATE as usize];
        s[3 * RATE as usize] = 1;
        let w = wav(&s);
        let cut = data_offset(&w).unwrap() + 2 * 3 * RATE as usize + 1;
        let mut split = Health::new(None);
        assert_eq!(split.step(&w[..cut], None), Verdict::Ok);
        assert_eq!(split.step(&w, None), Verdict::Ok, "a split sample is not lost");

        let mut speech = Health::new(None);
        let mut s = vec![0i16; 6 * RATE as usize];
        s[3 * RATE as usize] = 200;
        assert_eq!(speech.step(&wav(&s), None), Verdict::Ok);
    }

    #[test]
    fn unplugging_the_mic_mid_dictation_stops_with_an_alert() {
        let all = from_pw_dump(&fixture("pw-dump-mics.json"));
        let unplugged = from_pw_dump(&fixture("pw-dump-mics-unplugged.json"));
        let mut h = Health::new(Some(all[1].clone()));
        let w = wav(&[5; 100]);
        assert_eq!(h.step(&w, Some(&all)), Verdict::Ok);
        assert_eq!(h.step(&w, None), Verdict::Ok, "no poll this time");
        assert_eq!(h.step(&w, Some(&unplugged)), Verdict::Stop(Alert::Disconnected(YETI.into())));
        // Another mic going away does not stop this dictation.
        let mut other = Health::new(Some(all[2].clone()));
        assert_eq!(other.step(&w, Some(&unplugged)), Verdict::Ok);
    }

    #[test]
    fn alerts_are_rate_limited_per_kind() {
        let mut r = RateLimit::new(ALERT_EVERY);
        let t = Instant::now();
        assert!(r.allow(&Alert::NoAudio("a".into()), t));
        assert!(!r.allow(&Alert::NoAudio("b".into()), t + Duration::from_secs(59)), "same kind within 60 s");
        assert!(r.allow(&Alert::Disconnected("a".into()), t + Duration::from_secs(1)), "another kind is not held back");
        assert!(r.allow(&Alert::NoAudioServer, t));
        assert!(r.allow(&Alert::NoAudio("a".into()), t + ALERT_EVERY), "allowed again after the window");
        assert!(!r.allow(&Alert::NoAudio("a".into()), t + ALERT_EVERY + Duration::from_secs(1)));
    }

    #[test]
    fn the_indicator_gets_a_few_words_and_no_device_name() {
        // Goal rule 3: 🤫 stays tiny. A long device name or advice belongs in the notification.
        let long = "Yeti Stereo Microphone Analog Stereo".to_string();
        for a in [Alert::NoAudio(long.clone()), Alert::Disconnected(long.clone()), Alert::Unreadable(long.clone()),
                  Alert::NoAudioServer, Alert::Bluetooth(long.clone()), Alert::Clamshell] {
            assert!(a.short().len() <= 30 && !a.short().contains("Yeti"), "{:?}", a.short());
            assert!(a.text().len() > a.short().len());
        }
    }

    #[test]
    fn real_audio_resets_the_silence_count() {
        // As the Mac's MicTests.testRealAudioResetsTheSilenceCount: 4.9 s of zeros, one real
        // sample, 4.9 s of zeros again is no alert; the run only counts from the reset.
        let ms = |n: usize| n * RATE as usize / 1000;
        let mut s = vec![0i16; ms(4900)];
        s.push(300);
        s.extend(vec![0; ms(4900)]);
        let mut h = Health::new(None);
        assert_eq!(h.step(&wav(&s), None), Verdict::Ok);
        s.extend(vec![0; ms(200)]);
        assert_eq!(h.step(&wav(&s), None), Verdict::Alert(Alert::NoAudio("the mic".into())), "5.1 s since the reset");
        s.extend(vec![0; ms(5000)]);
        assert_eq!(h.step(&wav(&s), None), Verdict::Ok, "warned once");
    }

    #[test]
    fn no_samples_for_5_s_stops_with_mic_unreadable() {
        let mic = from_pw_dump(&fixture("pw-dump-mics.json"))[1].clone();
        let steps = (NO_FRAMES_AFTER.as_millis() / WATCH_EVERY.as_millis()) as usize;
        assert_eq!(steps, 10);
        let mut h = Health::new(Some(mic.clone()));
        let mut w = wav(&[5; 800]);
        assert_eq!(h.step(&w, None), Verdict::Ok);
        // The file stops growing: 4.5 s is fine, 5 s stops the recorder.
        for _ in 1..steps {
            assert_eq!(h.step(&w, None), Verdict::Ok);
        }
        // New samples before the 5 s are up start the count again.
        w.extend_from_slice(&[9, 0]);
        assert_eq!(h.step(&w, None), Verdict::Ok);
        for _ in 1..steps {
            assert_eq!(h.step(&w, None), Verdict::Ok);
        }
        assert_eq!(h.step(&w, None), Verdict::Stop(Alert::Unreadable(YETI.into())));

        // A file that cannot be read (read as empty), or a header and no samples ever: the same.
        let mut never = Health::new(None);
        let header = wav(&[]);
        let verdicts: Vec<_> = (0..steps).map(|i| never.step(if i % 2 == 0 { &[] } else { &header }, None)).collect();
        assert_eq!(verdicts.last(), Some(&Verdict::Stop(Alert::Unreadable("the mic".into()))));
        assert!(verdicts[..steps - 1].iter().all(|v| *v == Verdict::Ok));

        // A mic sending zeros does send frames: that is "no sound", not "unreadable".
        let mut zeros = Health::new(None);
        let mut s = vec![];
        let got: Vec<_> = (0..2 * steps).map(|_| {
            s.extend(vec![0i16; RATE as usize / 2]);
            zeros.step(&wav(&s), None)
        }).collect();
        assert!(got.iter().all(|v| !matches!(v, Verdict::Stop(_))), "{got:?}");
        assert!(got.contains(&Verdict::Alert(Alert::NoAudio("the mic".into()))));
    }

    #[test]
    fn a_bluetooth_headset_mic_is_advised_once() {
        let src = from_pw_dump(&fixture("pw-dump-mics.json"));
        let jabra = src.iter().find(|x| x.bus == "bluetooth").unwrap().clone();
        let mut n = Notices::default();
        assert_eq!(n.opening(&src[1], &src, false), None, "a USB mic");
        assert_eq!(n.opening(&jabra, &src, false), Some(Alert::Bluetooth(JABRA.into())));
        assert_eq!(n.opening(&jabra, &src, false), None, "once per run");
        // Nothing better to suggest: only the headset, or only the built-in mic under a closed lid.
        let mut alone = Notices::default();
        assert_eq!(alone.opening(&jabra, &[jabra.clone()], false), None);
        assert_eq!(alone.opening(&jabra, &[jabra.clone(), src[0].clone()], true), None);
        assert_eq!(alone.opening(&jabra, &[jabra.clone(), src[0].clone()], false), Some(Alert::Bluetooth(JABRA.into())));
    }

    #[test]
    fn the_lid_closed_on_the_only_mic_is_advised_once() {
        let builtin = from_pw_dump(&fixture("pw-dump-mics.json"))[0].clone();
        assert!(builtin.builtin);
        let mut n = Notices::default();
        assert_eq!(n.opening(&builtin, &[builtin.clone()], false), None, "lid open");
        assert_eq!(n.opening(&builtin, &[builtin.clone()], true), Some(Alert::Clamshell));
        assert_eq!(n.opening(&builtin, &[builtin.clone()], true), None, "once per run");
    }

    #[test]
    fn advice_is_a_hint_and_problems_are_errors() {
        // Goal rule 3: everything shows at 🤫. Advice must not turn it yellow as an error does.
        let lines = std::sync::Arc::new(Mutex::new(vec![]));
        let l = lines.clone();
        set_hint_sink(move |line| l.lock().unwrap().push(line.to_string()));
        let notes = std::sync::Arc::new(Mutex::new(vec![]));
        let notify = |t: &str| notes.lock().unwrap().push(t.to_string());
        assert!(show(Alert::Bluetooth(JABRA.into()), notify));
        assert!(show(Alert::Unreadable(YETI.into()), notify));
        assert!(show(Alert::Clamshell, notify));
        assert_eq!(*lines.lock().unwrap(), ["hint Bluetooth mic: lower quality", "error Cannot read the mic", "hint Lid closed: mic muffled"]);
        let notes = notes.lock().unwrap().clone();
        assert!(notes[0].starts_with("Jabra Evolve2 65 is a Bluetooth headset") && notes[1].starts_with("Cannot read Yeti"), "{notes:?}");
        assert!(!show(Alert::Unreadable(YETI.into()), |_| panic!("shown twice")), "rate-limited per kind");
        for a in [Alert::Bluetooth(JABRA.into()), Alert::Clamshell] {
            assert!(a.advice());
        }
        for a in [Alert::NoAudio(YETI.into()), Alert::Disconnected(YETI.into()), Alert::Unreadable(YETI.into()), Alert::NoAudioServer] {
            assert!(!a.advice());
        }
    }

    #[test]
    fn config_reads_only_mic_prefer() {
        assert!(parse_prefs("").is_empty());
        assert!(parse_prefs("prefer = [\"x\"]\n").is_empty(), "outside [mic]");
        assert!(parse_prefs("[other]\nprefer = [\"x\"]\n").is_empty());
        assert_eq!(parse_prefs("[mic]\nforce = \"z\"\nprefer = [ \"USB # 2\", \"\" ] # tail\n"), ["USB # 2"]);
        assert_eq!(config_path(None, "/home/p"), PathBuf::from("/home/p/.config/shepetal/config.toml"));
        assert_eq!(config_path(Some("rel"), "/home/p"), PathBuf::from("/home/p/.config/shepetal/config.toml"));
        assert_eq!(config_path(Some("/x"), "/home/p"), PathBuf::from("/x/shepetal/config.toml"));
    }

    #[test]
    fn records_from_the_picked_mic() {
        let yeti = from_pw_dump(&fixture("pw-dump-mics.json"))[1].clone();
        let n = yeti.name.clone();
        assert_eq!(target_args("pw-record", Some(&yeti)), ["--target".to_string(), n.clone()]);
        assert_eq!(target_args("parecord", Some(&yeti)), [format!("--device={n}")]);
        assert!(target_args("pw-record", None).is_empty());
    }

    #[test]
    fn mics_command_lists_in_rank_order() {
        let src = from_pw_dump(&fixture("pw-dump-mics.json"));
        let out = describe(&src, &["Jabra".into()], true);
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines.len(), 4);
        assert!(lines[0].starts_with(" 1. * Jabra Evolve2 65 [bluetooth]") && lines[0].contains("preference #1 \"Jabra\""), "{out}");
        assert!(lines[1].contains(WEBCAM) && lines[1].contains("desktop default"));
        assert!(lines[3].contains(BUILTIN) && lines[3].contains("lid closed"));
        assert_eq!(describe(&[], &[], false), "no input sources found\n");
    }
}
