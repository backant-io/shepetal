use shepetal::gesture::{Action, Event, Gesture};
use shepetal::{insert, meeting, model};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const USAGE: &str = "usage: shepetal probe [--pw-dump FILE] | shepetal daemon\n\
env: SHEPETAL_KEY (default fn), SHEPETAL_MODEL (path to the model `probe` names: a sherpa-onnx dir or a ggml .bin)";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let res = match args.first().map(String::as_str) {
        Some("probe") => probe(args.get(1).filter(|a| *a == "--pw-dump").and(args.get(2))),
        Some("daemon") => daemon(),
        _ => Err(USAGE.into()),
    };
    if let Err(e) = res {
        eprintln!("shepetal: {e}");
        std::process::exit(1);
    }
}

type Res = Result<(), String>;

const NO_FN: &str = "fn is not visible to Linux on this keyboard: no /dev/input/event* device reports KEY_FN (464).\n\
Many laptops handle fn in firmware and never send it to the system. Pick another key and start again:\n  \
SHEPETAL_KEY=rightalt shepetal daemon\n\
SHEPETAL_KEY takes rightalt, rightmeta, capslock, f13, rightctrl or an evdev key code number.";

const SYS_INPUT: &str = "/sys/class/input";
/// ydotoold's uinput device declares every key, KEY_FN included, but only replays what
/// `ydotool type` sends. ydotool 0.1.8 (Ubuntu 24.04) registers it as BUS_USB through
/// libuInputPlus and 1.x as BUS_VIRTUAL, so only the name, which both use, identifies it.
// ponytail: skips ydotoold only; any other uinput device that declares fn still counts.
// Skipping all of /sys/devices/virtual would also drop a remapper's (keyd) virtual keyboard,
// which is then the only device that sends real keys.
const YDOTOOLD: &str = "ydotoold virtual device";

fn env(k: &str) -> String {
    std::env::var(k).unwrap_or_default()
}

fn backend() -> Option<insert::Backend> {
    let (session, desktop) = (env("XDG_SESSION_TYPE"), env("XDG_CURRENT_DESKTOP"));
    insert::choose(&insert::Env { session: &session, desktop: &desktop }, insert::on_path)
}

fn data_home() -> String {
    data_home_from(std::env::var("XDG_DATA_HOME").ok().as_deref(), &env("HOME"))
}

/// The XDG Base Directory spec: an empty or relative XDG_DATA_HOME is ignored, so the kept
/// audio never lands under the daemon's working directory (which can be /tmp).
fn data_home_from(xdg: Option<&str>, home: &str) -> String {
    match xdg {
        Some(d) if d.starts_with('/') => d.to_string(),
        _ => format!("{home}/.local/share"),
    }
}

fn model_path(m: &model::Choice) -> PathBuf {
    if let Ok(p) = std::env::var("SHEPETAL_MODEL") {
        return p.into();
    }
    PathBuf::from(data_home()).join("shepetal").join(m.model)
}

fn probe(dump_file: Option<&String>) -> Res {
    let hw = model::detect();
    let choice = model::choose(&hw);
    println!("hardware:  {} GB RAM, {} cores, cuda={}, vulkan={}", hw.ram_gb, hw.cores, hw.cuda, hw.vulkan);
    println!("model:     {} ({:?}) on {} ({})", choice.model, choice.engine, choice.backend, model_path(&choice).display());
    println!("session:   {:?} desktop {:?}", env("XDG_SESSION_TYPE"), env("XDG_CURRENT_DESKTOP"));
    println!("insert:    {:?}", backend());
    let fns = keyboards_with(Path::new(SYS_INPUT), shepetal::KEY_FN);
    if fns.is_empty() {
        println!("fn key:    not visible to Linux (many laptops handle fn in firmware); set SHEPETAL_KEY, e.g. rightalt");
    }
    for (dev, name) in &fns {
        println!("fn key:    visible on {} ({name})", dev.display());
    }
    let json = match dump_file {
        Some(f) => std::fs::read_to_string(f).map_err(|e| format!("{f}: {e}"))?,
        None => match Command::new("pw-dump").output() {
            Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
            Err(e) => {
                println!("mic users: unknown (pw-dump: {e})");
                return Ok(());
            }
        },
    };
    let dump: serde_json::Value = serde_json::from_str(&json).map_err(|e| format!("pw-dump json: {e}"))?;
    for s in meeting::mic_streams(&dump) {
        println!("mic user:  {} ({}) meeting={:?}", s.app, s.binary, s.meeting);
    }
    println!("system audio: {:?}", meeting::system_audio_source(&dump));
    Ok(())
}

/// The /dev/input/event* nodes under `sys` (/sys/class/input) whose key capabilities include
/// `key`, with their names. The kernel drops events for keys a device does not declare, so the
/// others cannot send it. ydotoold is skipped: it never sends a key the user pressed.
fn keyboards_with(sys: &Path, key: u16) -> Vec<(PathBuf, String)> {
    let Ok(dir) = std::fs::read_dir(sys) else { return vec![] };
    let mut out: Vec<_> = dir.flatten().filter_map(|e| {
        let node = e.file_name().to_string_lossy().into_owned();
        let caps = std::fs::read_to_string(e.path().join("device/capabilities/key")).ok()?;
        let name = std::fs::read_to_string(e.path().join("device/name")).unwrap_or_default().trim().to_string();
        if !node.starts_with("event") || !shepetal::has_key(&caps, key) || name == YDOTOOLD {
            return None;
        }
        Some((PathBuf::from("/dev/input").join(node), name))
    }).collect();
    out.sort();
    out
}

/// The hotkey (`SHEPETAL_KEY`, else fn), its name, and the keyboards under `sys` that can send
/// it. None is an error: the daemon must not start and wait for a key that never arrives.
fn hotkey_keyboards(sys: &Path) -> Result<(u16, String, Vec<(PathBuf, String)>), String> {
    let key_env = std::env::var("SHEPETAL_KEY").ok();
    // A raw evdev code reads "Hold key 58 to talk" in the hint, not "Hold 58 to talk".
    let key_name = match key_env.as_deref() {
        None => "fn".into(),
        Some(k) if k.parse::<u16>().is_ok() => format!("key {k}"),
        Some(k) => k.to_string(),
    };
    let key = shepetal::hotkey(key_env.as_deref()).ok_or(format!("unknown SHEPETAL_KEY {key_name:?}"))?;
    let devs = keyboards_with(sys, key);
    if devs.is_empty() {
        return Err(match key {
            shepetal::KEY_FN => NO_FN.into(),
            _ => format!("no keyboard reports SHEPETAL_KEY {key_name:?} (evdev code {key})"),
        });
    }
    Ok((key, key_name, devs))
}

/// One thread per keyboard; each sends (code, value) of key events.
fn watch_keys(tx: mpsc::Sender<(u16, i32)>, devs: &[(PathBuf, String)]) -> Res {
    let mut opened = 0;
    for (path, _) in devs {
        let Ok(mut f) = std::fs::File::open(path) else { continue };
        opened += 1;
        let tx = tx.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; 24];
            while f.read_exact(&mut buf).is_ok() {
                if let Some(k) = shepetal::key_event(&buf) {
                    if tx.send(k).is_err() {
                        return;
                    }
                }
            }
        });
    }
    if opened == 0 {
        return Err("cannot read any /dev/input/event*: run `sudo usermod -aG input $USER` and log in again".into());
    }
    Ok(())
}

fn record(wav: &PathBuf) -> std::io::Result<Child> {
    if insert::on_path("pw-record") {
        Command::new("pw-record")
            .args(["--rate", "16000", "--channels", "1", "--format", "s16", "-P", "{ application.name = shepetal }"])
            .arg(wav)
            .spawn()
    } else {
        Command::new("parecord")
            .args(["--rate=16000", "--channels=1", "--format=s16le", "--file-format=wav"])
            .arg(wav)
            .spawn()
    }
}

/// SIGINT so the recorder finalizes the WAV header; SIGKILL would leave it broken.
fn stop(mut child: Child) {
    let _ = Command::new("kill").args(["-INT", &child.id().to_string()]).status();
    let _ = child.wait();
}

/// Run the engine the tier table picked (docs/models.md) on `wav` and return the text.
fn transcribe(m: &model::Choice, wav: &Path) -> Result<String, String> {
    use model::Engine::*;
    let path = model_path(m);
    let file = |flag: &str, name: &str| {
        let mut a = std::ffi::OsString::from(format!("--{flag}="));
        a.push(path.join(name));
        a
    };
    let mut cmd = Command::new(if m.engine == Whisper { "whisper-cli" } else { "sherpa-onnx-offline" });
    match m.engine {
        Whisper => cmd.arg("-m").arg(&path).arg("-f").arg(wav).args(["-nt", "-np", "-l", "auto"]),
        SherpaTransducer => cmd
            .args([file("encoder", "encoder.int8.onnx"), file("decoder", "decoder.int8.onnx"), file("joiner", "joiner.int8.onnx")])
            .arg("--model-type=nemo_transducer"),
        SherpaCtc => cmd.arg(file("nemo-ctc-model", "model.int8.onnx")),
    };
    if m.engine != Whisper {
        // A CPU-only sherpa-onnx build logs "Fallback to cpu!" for --provider=cuda and still runs.
        cmd.arg(file("tokens", "tokens.txt")).arg(format!("--provider={}", m.backend)).arg("--num-threads=4").arg(wav);
    }
    let bin = cmd.get_program().to_string_lossy().into_owned();
    let out = cmd.output().map_err(|e| format!("{bin}: {e}"))?;
    if !out.status.success() {
        return Err(format!("{bin}: {}", String::from_utf8_lossy(&out.stderr)));
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let text = if m.engine == Whisper {
        without_markers(&stdout)
    } else {
        // sherpa-onnx-offline logs to stderr and prints one JSON result line per file on stdout.
        let v: serde_json::Value = serde_json::from_str(stdout.trim()).map_err(|e| format!("{bin} output: {e}"))?;
        v["text"].as_str().ok_or(format!("{bin} output has no text"))?.to_string()
    };
    Ok(text.split_whitespace().collect::<Vec<_>>().join(" "))
}

/// whisper.cpp writes non-speech as bracketed markers (`[BLANK_AUDIO]`, `[Music]`); they must
/// not be typed at the cursor.
fn without_markers(s: &str) -> String {
    // An `[` that is never closed is not a marker: keep the text after it.
    if s.matches('[').count() > s.matches(']').count() {
        return s.to_string();
    }
    let mut out = String::new();
    let mut depth = 0;
    for c in s.chars() {
        match c {
            '[' => depth += 1,
            ']' if depth > 0 => depth -= 1,
            ']' => {}
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out
}

fn daemon() -> Res {
    let (key, key_name, devs) = hotkey_keyboards(Path::new(SYS_INPUT))?;
    let choice = model::choose(&model::detect());
    let model = model_path(&choice);
    if !model.exists() {
        return Err(format!("model missing: {} (see docs/linux.md)", model.display()));
    }
    let typer = backend().ok_or("no text insertion tool: install wtype, xdotool, ydotool, wl-clipboard or xclip")?;
    let data_home = PathBuf::from(data_home());

    let (tx, rx) = mpsc::channel();
    watch_keys(tx, &devs)?;
    let names: Vec<_> = devs.iter().map(|(p, n)| format!("{} ({n})", p.display())).collect();
    eprintln!("shepetal: hold {key_name} to talk, double-tap for hands-free. keyboards {}, model {}, insert {typer:?}", names.join(", "), choice.model);

    listen(&rx, key, &key_name, &data_home, &choice, typer)
}

/// Wait up to 50 ms for a key event and turn it into a gesture event. `Ok(None)` is a key event
/// the gesture ignores: another key's release, or autorepeat (value 2).
fn next_event(rx: &mpsc::Receiver<(u16, i32)>, key: u16, t0: Instant) -> Result<Option<Event>, String> {
    let got = rx.recv_timeout(Duration::from_millis(50));
    // Stamp after the wait. Read before it, an event got the time the wait began, up to 50 ms
    // early, which moved presses across the 500 ms line between a tap and a hold.
    let now = t0.elapsed().as_millis() as u64;
    Ok(Some(match got {
        Ok((code, 1)) if code == key => Event::Down(now),
        Ok((code, 0)) if code == key => Event::Up(now),
        Ok((_, 1)) => Event::Other,
        Ok(_) => return Ok(None),
        Err(mpsc::RecvTimeoutError::Timeout) => Event::Tick(now),
        Err(mpsc::RecvTimeoutError::Disconnected) => return Err("all input devices closed".into()),
    }))
}

/// The dictation loop. It returns only on an error, and never with a recorder still running.
fn listen(rx: &mpsc::Receiver<(u16, i32)>, key: u16, key_name: &str, data_home: &Path, stt: &model::Choice, typer: insert::Backend) -> Res {
    let t0 = Instant::now();
    let mut g = Gesture::default();
    let mut rec: Option<(Child, PathBuf)> = None;
    loop {
        let ev = match next_event(rx, key, t0) {
            Ok(ev) => ev,
            Err(e) => {
                // Every keyboard is gone, e.g. a Bluetooth one slept mid-recording. Rust does not
                // kill children on exit, so the recorder would keep the mic open after shepetal.
                // Stop it, and keep the clip as cancelled.
                act(Action::Cancel, &mut rec, data_home, stt, typer, key_name)?;
                return Err(e);
            }
        };
        // A tick after every event too, not only after 50 ms without one: while the user types
        // or holds a key after a tap, the tap must still end as too short when its window runs
        // out, and the recorder must stop then.
        let tick = Event::Tick(t0.elapsed().as_millis() as u64);
        for ev in ev.into_iter().chain([tick]) {
            for a in g.feed(ev) {
                // ponytail: stderr until the 🤫 overlay lands, which shows the hint for about 2 s.
                if let Some(hint) = act(a, &mut rec, data_home, stt, typer, key_name)? {
                    eprintln!("shepetal: hint: {hint}");
                }
            }
        }
    }
}

/// Carry out one gesture action. `rec` is the running recorder and the WAV it writes.
/// Returns the hint to show next to 🤫 after a too-short press.
fn act(a: Action, rec: &mut Option<(Child, PathBuf)>, data_home: &Path, stt: &model::Choice, typer: insert::Backend, key_name: &str) -> Result<Option<String>, String> {
    match a {
        Action::Start => {
            let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis();
            let wav = shepetal::new_recording(data_home, stamp).map_err(|e| format!("audio file: {e}"))?;
            *rec = Some((record(&wav).map_err(|e| format!("recorder: {e}"))?, wav));
        }
        Action::Cancel | Action::TooShort => {
            let label = if a == Action::Cancel { "cancelled" } else { "tooshort" };
            if let Some((c, wav)) = rec.take() {
                stop(c);
                if let Err(e) = shepetal::mark(&wav, label) {
                    eprintln!("shepetal: mark {label} {}: {e}", wav.display());
                }
            }
            return Ok((a == Action::TooShort).then(|| shepetal::short_press_hint(key_name)));
        }
        Action::Stop => {
            let Some((c, wav)) = rec.take() else { return Ok(None) };
            stop(c);
            // ponytail: transcribes on the input thread, so keys pressed meanwhile queue up.
            // The WAV stays in the audio history: it is exactly what the model heard.
            match transcribe(stt, &wav) {
                Ok(t) if !t.is_empty() => {
                    if let Err(e) = typer.insert(&t) {
                        eprintln!("shepetal: insert: {e}");
                    }
                }
                Ok(_) => {}
                Err(e) => eprintln!("shepetal: {e}"),
            }
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fake /sys/class/input with `<node>/device/{name,capabilities/key}` per device.
    fn fake_sys(tag: &str, devs: &[(&str, &str, &str)]) -> PathBuf {
        let root = std::env::temp_dir().join(format!("shepetal-sys-{tag}-{}", std::process::id()));
        for (node, name, keys) in devs {
            let d = root.join(node).join("device");
            std::fs::create_dir_all(d.join("capabilities")).unwrap();
            std::fs::write(d.join("name"), format!("{name}\n")).unwrap();
            std::fs::write(d.join("capabilities/key"), keys).unwrap();
        }
        root
    }

    // Key bitmaps as the kernel prints them: 64-bit words, most significant first.
    const FN: &str = "10000 0 0 0 0 0 0 0\n"; // KEY_FN (464): word 7, bit 16
    const RCTRL: &str = "200000000 0\n"; // KEY_RIGHTCTRL (97): word 1, bit 33
    const BOTH: &str = "10000 0 0 0 0 0 200000000 0\n"; // ydotoold declares both, and more

    #[test]
    fn daemon_waits_for_fn_only_on_keyboards_that_can_send_it() {
        let laptop_kbd = ("event2", "AT Translated Set 2 keyboard", RCTRL);
        let ydotoold = ("event9", YDOTOOLD, BOTH);
        let _lock = PATH_LOCK.lock().unwrap_or_else(|e| e.into_inner()); // SHEPETAL_KEY is process-wide
        let desk = fake_sys("desk", &[laptop_kbd, ("event5", "Apple keyboard", FN), ydotoold]);
        let laptop = fake_sys("laptop", &[laptop_kbd, ydotoold]);
        std::env::remove_var("SHEPETAL_KEY");

        // Pavel's decision: with SHEPETAL_KEY unset the daemon records on fn, never Right Ctrl.
        let (key, name, devs) = hotkey_keyboards(&desk).unwrap();
        assert_eq!((key, name.as_str()), (shepetal::KEY_FN, "fn"));
        // Only keyboards that declare fn are read; ydotoold declares it but never sends a real key.
        assert_eq!(devs, [(PathBuf::from("/dev/input/event5"), "Apple keyboard".to_string())]);

        // Firmware fn with ydotoold running (GNOME Wayland): exit with the fn advice, not listen
        // on ydotoold forever.
        assert_eq!(hotkey_keyboards(&laptop).unwrap_err(), NO_FN);

        std::env::set_var("SHEPETAL_KEY", "rightctrl");
        let (key, _, devs) = hotkey_keyboards(&laptop).unwrap();
        std::env::remove_var("SHEPETAL_KEY");
        assert_eq!((key, devs.len()), (97, 1), "SHEPETAL_KEY overrides fn, ydotoold still skipped");
        std::fs::remove_dir_all(desk).unwrap();
        std::fs::remove_dir_all(laptop).unwrap();
    }

    /// The tier table's choice for a 16 GB, 8-core machine without a GPU: Parakeet v3 on CPU.
    fn cpu() -> model::Choice {
        model::choose(&model::Hardware { ram_gb: 16, cores: 8, cuda: false, vulkan: false })
    }

    /// Runs `a` on a fake recording `<stamp>.wav` holding "RIFF" and returns the hint.
    fn act_on_clip(a: Action, home: &Path, stamp: u128) -> Option<String> {
        let wav = shepetal::new_recording(home, stamp).unwrap();
        std::fs::write(&wav, b"RIFF").unwrap();
        let mut rec = Some((Command::new("true").spawn().unwrap(), wav.clone()));
        let hint = act(a, &mut rec, home, &cpu(), insert::Backend::Wtype, "fn").unwrap();
        assert!(rec.is_none());
        assert!(!wav.exists());
        hint
    }

    #[test]
    fn cancel_keeps_the_recording() {
        // Pavel's decision: every clip is kept, a cancelled one as <stamp>.cancelled.wav.
        let home = std::env::temp_dir().join(format!("shepetal-cancel-{}", std::process::id()));
        assert_eq!(act_on_clip(Action::Cancel, &home, 7), None, "an fn chord shows no hint");
        assert_eq!(std::fs::read(home.join("shepetal/audio/7.cancelled.wav")).unwrap(), b"RIFF");
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn too_short_press_keeps_the_clip_and_shows_the_hint() {
        // Goal rule 2: the clip is not transcribed but kept, marked too short, and the hint
        // names the key.
        let home = std::env::temp_dir().join(format!("shepetal-short-{}", std::process::id()));
        let hint = act_on_clip(Action::TooShort, &home, 8);
        assert_eq!(hint.as_deref(), Some("Hold fn to talk · double-tap for hands-free"));
        assert_eq!(std::fs::read(home.join("shepetal/audio/8.tooshort.wav")).unwrap(), b"RIFF");
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn evdev_key_values_become_gesture_events() {
        // value 1 is a press, 0 a release, 2 autorepeat. Swapping press and release, or losing
        // the other key's press that makes fn+F1 a chord, must fail here.
        const F1: u16 = 59;
        let (tx, rx) = mpsc::channel();
        for k in [(shepetal::KEY_FN, 1), (shepetal::KEY_FN, 2), (F1, 1), (F1, 2), (F1, 0), (shepetal::KEY_FN, 0)] {
            tx.send(k).unwrap();
        }
        let t0 = Instant::now();
        let next = || next_event(&rx, shepetal::KEY_FN, t0);
        assert!(matches!(next(), Ok(Some(Event::Down(_)))), "fn press");
        assert_eq!(next(), Ok(None), "fn autorepeat while it is held");
        assert_eq!(next(), Ok(Some(Event::Other)), "F1 press while fn is down: the chord that cancels");
        assert_eq!(next(), Ok(None), "F1 autorepeat");
        assert_eq!(next(), Ok(None), "F1 release");
        assert!(matches!(next(), Ok(Some(Event::Up(_)))), "fn release");
        assert!(matches!(next(), Ok(Some(Event::Tick(_)))), "no key for 50 ms");
        drop(tx);
        assert_eq!(next(), Err("all input devices closed".into()));
    }

    #[test]
    fn a_key_event_is_stamped_when_it_arrives() {
        // The 500 ms line between a tap and a hold needs the time of the key event. Stamped when
        // the 50 ms wait began, a 505 ms hold was dropped as too short and a 480 ms tap typed.
        let (tx, rx) = mpsc::channel();
        let t0 = Instant::now();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(30));
            tx.send((shepetal::KEY_FN, 1)).unwrap();
        });
        let t = loop {
            match next_event(&rx, shepetal::KEY_FN, t0) {
                Ok(Some(Event::Down(t))) => break t,
                Ok(Some(Event::Tick(_))) => {} // the sender was scheduled late
                e => panic!("{e:?}"),
            }
        };
        assert!(t >= 30, "fn pressed at 30 ms or later, stamped {t} ms");
    }

    static PATH_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// Runs `f(d)` with fake pw-record, sherpa-onnx-offline, whisper-cli and wtype first on PATH.
    /// They write into the fresh dir `d`: rec.args and stt.args (their argv), heard.wav (a copy of
    /// the file the model read) and typed (wtype's stdin). The recorder writes "RIFF partial"
    /// once its SIGINT trap is set and "RIFF final" on SIGINT, the way pw-record finishes the
    /// WAV header. SIGKILL leaves "RIFF partial".
    fn with_fake_tools(tag: &str, f: impl FnOnce(&Path)) {
        use std::os::unix::fs::PermissionsExt;
        let _lock = PATH_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let d = std::env::temp_dir().join(format!("shepetal-tools-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let d_ = d.display();
        // The JSON line has the shape sherpa-onnx-offline v1.13.8 prints on stdout.
        // The text holds a newline: typed as is, it would press Enter in the user's window.
        let sherpa_out = r#"{"lang": "", "emotion": "", "event": "", "text": " Hello\n  world.", "timestamps": [0.00, 0.08]}"#;
        let tools = [
            ("pw-record", format!("for f; do :; done\necho \"$*\" > \"{d_}/rec.args\"\ntrap 'printf \"RIFF final\" > \"$f\"; exit 0' INT\nprintf 'RIFF partial' > \"$f\"\ni=0; while [ $i -lt 1000 ]; do sleep 0.01; i=$((i+1)); done\n")),
            ("sherpa-onnx-offline", format!("echo \"$*\" > \"{d_}/stt.args\"\nfor f; do :; done\ncp \"$f\" \"{d_}/heard.wav\"\necho 'Started' >&2\nprintf '%s\\n' '{sherpa_out}'\n")),
            ("whisper-cli", format!("echo \"$*\" > \"{d_}/stt.args\"\ncp \"$4\" \"{d_}/heard.wav\"\nprintf ' [BLANK_AUDIO]\\n Hello\\n  world. [Music]\\n'\n")),
            ("wtype", format!("cat > \"{d_}/typed\"\n")),
        ];
        for (bin, body) in tools {
            std::fs::write(d.join(bin), format!("#!/bin/sh\n{body}")).unwrap();
            std::fs::set_permissions(d.join(bin), std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let path = std::env::var("PATH").unwrap_or_default();
        std::env::set_var("PATH", format!("{d_}:{path}"));
        f(&d);
        std::env::set_var("PATH", path);
        std::fs::remove_dir_all(&d).unwrap();
    }

    fn wait_until(what: &str, ok: impl Fn() -> bool) {
        for _ in 0..500 {
            if ok() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("timed out waiting for {what}");
    }

    fn clips(dir: &Path) -> Vec<PathBuf> {
        let mut v: Vec<_> = std::fs::read_dir(dir).map(|r| r.flatten().map(|e| e.path()).collect()).unwrap_or_default();
        v.sort();
        v
    }

    #[test]
    fn dictation_keeps_the_audio_the_model_heard() {
        // Goal rule 4 on the normal path: the clip is recorded at 16 kHz mono, finished with
        // SIGINT, kept owner-only in the audio history, and it is the file the model read.
        use std::os::unix::fs::PermissionsExt;
        with_fake_tools("stop", |d| {
            let home = d.join("home");
            let mut rec = None;
            act(Action::Start, &mut rec, &home, &cpu(), insert::Backend::Wtype, "fn").unwrap();
            let wav = rec.as_ref().unwrap().1.clone();
            wait_until("the recorder", || std::fs::read(&wav).is_ok_and(|b| b == b"RIFF partial"));
            assert_eq!(std::fs::read_to_string(d.join("rec.args")).unwrap(),
                format!("--rate 16000 --channels 1 --format s16 -P {{ application.name = shepetal }} {}\n", wav.display()));

            assert_eq!(act(Action::Stop, &mut rec, &home, &cpu(), insert::Backend::Wtype, "fn").unwrap(), None);
            assert!(rec.is_none());
            assert_eq!(clips(&home.join("shepetal/audio")), std::slice::from_ref(&wav), "kept under its own name, not marked");
            assert_eq!(std::fs::read(&wav).unwrap(), b"RIFF final", "finished by SIGINT, not killed");
            assert_eq!(std::fs::read(d.join("heard.wav")).unwrap(), b"RIFF final", "the model read the finished file");
            assert!(std::fs::read_to_string(d.join("stt.args")).unwrap().ends_with(&format!(" {}\n", wav.display())));
            let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
            assert_eq!((mode(&wav), mode(wav.parent().unwrap())), (0o600, 0o700));
            assert_eq!(std::fs::read_to_string(d.join("typed")).unwrap(), "Hello world.");
        });
    }

    #[test]
    fn losing_every_keyboard_mid_recording_stops_the_recorder() {
        // The only fn keyboard (often a Bluetooth one) sleeps while a recording runs. The daemon
        // exits, and the recorder must not keep the mic open after it. The clip is kept.
        with_fake_tools("lost", |d| {
            let home = d.join("home");
            let audio = home.join("shepetal/audio");
            let (tx, rx) = mpsc::channel();
            let watched = audio.clone();
            let keyboard = std::thread::spawn(move || {
                tx.send((shepetal::KEY_FN, 1)).unwrap();
                wait_until("the recorder", || clips(&watched).iter().any(|p| std::fs::read(p).is_ok_and(|b| b == b"RIFF partial")));
            }); // tx is dropped here: the keyboard is gone while fn is down
            let err = listen(&rx, shepetal::KEY_FN, "fn", &home, &cpu(), insert::Backend::Wtype).unwrap_err();
            keyboard.join().unwrap();
            assert_eq!(err, "all input devices closed");
            let kept = clips(&audio);
            assert_eq!(kept.len(), 1, "{kept:?}");
            assert!(kept[0].to_string_lossy().ends_with(".cancelled.wav"), "{kept:?}");
            assert_eq!(std::fs::read(&kept[0]).unwrap(), b"RIFF final", "the recorder got SIGINT before shepetal returned");
        });
    }

    #[test]
    fn whisper_markers_are_dropped_and_other_text_kept() {
        assert_eq!(without_markers(" [BLANK_AUDIO]\n Hello [Music] world."), " \n Hello  world.");
        assert_eq!(without_markers("Hello [world"), "Hello [world", "an unclosed [ is text");
        assert_eq!(without_markers("a ] b [x] c"), "a  b  c");
    }

    #[test]
    fn a_numeric_key_is_named_key_n_in_the_hint() {
        let _lock = PATH_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let sys = fake_sys("numkey", &[("event3", "kbd", "400000000000000\n")]); // KEY_CAPSLOCK (58)
        std::env::set_var("SHEPETAL_KEY", "58");
        let got = hotkey_keyboards(&sys);
        std::env::remove_var("SHEPETAL_KEY");
        std::fs::remove_dir_all(sys).unwrap();
        let (key, name, _) = got.unwrap();
        assert_eq!((key, shepetal::short_press_hint(&name).as_str()), (58, "Hold key 58 to talk · double-tap for hands-free"));
    }

    #[test]
    fn audio_never_goes_under_a_relative_or_empty_xdg_data_home() {
        assert_eq!(data_home_from(Some("/data/me"), "/home/me"), "/data/me");
        assert_eq!(data_home_from(None, "/home/me"), "/home/me/.local/share");
        assert_eq!(data_home_from(Some(""), "/home/me"), "/home/me/.local/share");
        assert_eq!(data_home_from(Some("tmp/x"), "/home/me"), "/home/me/.local/share");
    }

    #[test]
    fn a_tap_ends_as_too_short_on_time_while_a_key_repeats() {
        // Goal rule 2: tap fn, then hold Backspace. The tap must end as too short when the
        // 500 ms window runs out, not when the typing pauses, so the mic is not left open.
        with_fake_tools("repeat", |d| {
            let home = d.join("home");
            let audio = home.join("shepetal/audio");
            let (tx, rx) = mpsc::channel();
            let keyboard = std::thread::spawn(move || {
                tx.send((shepetal::KEY_FN, 1)).unwrap();
                wait_until("the recorder", || clips(&audio).iter().any(|p| std::fs::read(p).is_ok_and(|b| b == b"RIFF partial")));
                tx.send((shepetal::KEY_FN, 0)).unwrap();
                let up = Instant::now();
                tx.send((14, 1)).unwrap(); // KEY_BACKSPACE down, then autorepeat every 20 ms
                let too_short = || clips(&audio).iter().any(|p| p.to_string_lossy().ends_with(".tooshort.wav"));
                while !too_short() && up.elapsed() < Duration::from_millis(2000) {
                    tx.send((14, 2)).unwrap();
                    std::thread::sleep(Duration::from_millis(20));
                }
                up.elapsed()
            });
            assert_eq!(listen(&rx, shepetal::KEY_FN, "fn", &home, &cpu(), insert::Backend::Wtype).unwrap_err(), "all input devices closed");
            let took = keyboard.join().unwrap();
            assert!(took < Duration::from_millis(900), "too short only {took:?} after the release, while the key repeated");
            assert!(!d.join("typed").exists());
        });
    }

    #[test]
    fn transcribe_runs_the_engine_the_tier_table_picked() {
        // Goal rule 5: each docs/models.md Linux tier runs its own engine, model files and backend.
        with_fake_tools("stt", |d| {
            let wav = d.join("clip.wav");
            std::fs::write(&wav, b"RIFF").unwrap();
            let on = |ram_gb, cuda, vulkan| model::choose(&model::Hardware { ram_gb, cores: 8, cuda, vulkan });
            let parakeet = "--encoder={m}/encoder.int8.onnx --decoder={m}/decoder.int8.onnx --joiner={m}/joiner.int8.onnx --model-type=nemo_transducer --tokens={m}/tokens.txt";
            for (choice, args) in [
                (on(16, false, false), format!("{parakeet} --provider=cpu --num-threads=4 {{w}}")),
                (on(16, true, false), format!("{parakeet} --provider=cuda --num-threads=4 {{w}}")),
                (on(3, false, false), "--nemo-ctc-model={m}/model.int8.onnx --tokens={m}/tokens.txt --provider=cpu --num-threads=4 {w}".into()),
                (on(16, false, true), "-m {m} -f {w} -nt -np -l auto".into()),
            ] {
                assert_eq!(transcribe(&choice, &wav).as_deref(), Ok("Hello world."), "{choice:?}");
                let want = args.replace("{m}", &model_path(&choice).display().to_string()).replace("{w}", &wav.display().to_string());
                assert_eq!(std::fs::read_to_string(d.join("stt.args")).unwrap(), want + "\n", "{choice:?}");
                assert_eq!(std::fs::read(d.join("heard.wav")).unwrap(), b"RIFF");
            }
        });
    }
}
