use shepetal::gesture::{Action, Event, Gesture};
use shepetal::{insert, meeting, model};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const USAGE: &str = "usage: shepetal probe [--pw-dump FILE] | shepetal daemon\n\
env: SHEPETAL_KEY (default fn), SHEPETAL_MODEL (path to a ggml .bin)";

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
    std::env::var("XDG_DATA_HOME").unwrap_or_else(|_| format!("{}/.local/share", env("HOME")))
}

fn model_path(m: &model::Choice) -> PathBuf {
    if let Ok(p) = std::env::var("SHEPETAL_MODEL") {
        return p.into();
    }
    PathBuf::from(data_home()).join("shepetal").join(format!("ggml-{}.bin", m.model))
}

fn probe(dump_file: Option<&String>) -> Res {
    let hw = model::detect();
    let choice = model::choose(&hw);
    println!("hardware:  {} GB RAM, {} cores, cuda={}, vulkan={}", hw.ram_gb, hw.cores, hw.cuda, hw.vulkan);
    println!("model:     {} on {} ({})", choice.model, choice.backend, model_path(&choice).display());
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
    let key_name = key_env.clone().unwrap_or_else(|| "fn".into());
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

fn transcribe(model: &PathBuf, wav: &PathBuf) -> Result<String, String> {
    let out = Command::new("whisper-cli")
        .arg("-m").arg(model).arg("-f").arg(wav)
        .args(["-nt", "-np", "-l", "auto"])
        .output()
        .map_err(|e| format!("whisper-cli: {e}"))?;
    if !out.status.success() {
        return Err(format!("whisper-cli: {}", String::from_utf8_lossy(&out.stderr)));
    }
    let text = String::from_utf8_lossy(&out.stdout);
    Ok(text.split_whitespace().collect::<Vec<_>>().join(" "))
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

    let t0 = Instant::now();
    let mut g = Gesture::default();
    let mut rec: Option<(Child, PathBuf)> = None;
    loop {
        let now = t0.elapsed().as_millis() as u64;
        let ev = match rx.recv_timeout(Duration::from_millis(50)) {
            Ok((code, 1)) if code == key => Event::Down(now),
            Ok((code, 0)) if code == key => Event::Up(now),
            Ok((_, 1)) => Event::Other,
            Ok(_) => continue,
            Err(mpsc::RecvTimeoutError::Timeout) => Event::Tick(now),
            Err(mpsc::RecvTimeoutError::Disconnected) => return Err("all input devices closed".into()),
        };
        for a in g.feed(ev) {
            // ponytail: stderr until the 🤫 overlay lands, which shows the hint for about 2 s.
            if let Some(hint) = act(a, &mut rec, &data_home, &model, typer, &key_name)? {
                eprintln!("shepetal: hint: {hint}");
            }
        }
    }
}

/// Carry out one gesture action. `rec` is the running recorder and the WAV it writes.
/// Returns the hint to show next to 🤫 after a too-short press.
fn act(a: Action, rec: &mut Option<(Child, PathBuf)>, data_home: &Path, model: &PathBuf, typer: insert::Backend, key_name: &str) -> Result<Option<String>, String> {
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
            match transcribe(model, &wav) {
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

    /// Runs `a` on a fake recording `<stamp>.wav` holding "RIFF" and returns the hint.
    fn act_on_clip(a: Action, home: &Path, stamp: u128) -> Option<String> {
        let wav = shepetal::new_recording(home, stamp).unwrap();
        std::fs::write(&wav, b"RIFF").unwrap();
        let mut rec = Some((Command::new("true").spawn().unwrap(), wav.clone()));
        let hint = act(a, &mut rec, home, &PathBuf::new(), insert::Backend::Wtype, "fn").unwrap();
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
}
