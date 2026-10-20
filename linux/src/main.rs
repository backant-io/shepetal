use shepetal::gesture::{Action, Event, Gesture};
use shepetal::{insert, meeting, model};
use std::io::Read;
use std::path::PathBuf;
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
    let fns = keyboards_with(shepetal::KEY_FN);
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

/// The /dev/input/event* nodes whose sysfs key capabilities include `key`, with their names.
/// The kernel drops events for keys a device does not declare, so the others cannot send it.
fn keyboards_with(key: u16) -> Vec<(PathBuf, String)> {
    let Ok(dir) = std::fs::read_dir("/sys/class/input") else { return vec![] };
    let mut out: Vec<_> = dir.flatten().filter_map(|e| {
        let node = e.file_name().to_string_lossy().into_owned();
        let caps = std::fs::read_to_string(e.path().join("device/capabilities/key")).ok()?;
        if !node.starts_with("event") || !shepetal::has_key(&caps, key) {
            return None;
        }
        let name = std::fs::read_to_string(e.path().join("device/name")).unwrap_or_default();
        Some((PathBuf::from("/dev/input").join(node), name.trim().to_string()))
    }).collect();
    out.sort();
    out
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
    let key_env = std::env::var("SHEPETAL_KEY").ok();
    let key_name = key_env.as_deref().unwrap_or("fn");
    let key = shepetal::hotkey(key_env.as_deref()).ok_or(format!("unknown SHEPETAL_KEY {key_name:?}"))?;
    let devs = keyboards_with(key);
    if devs.is_empty() {
        return Err(match key {
            shepetal::KEY_FN => NO_FN.into(),
            _ => format!("no keyboard reports SHEPETAL_KEY {key_name:?} (evdev code {key})"),
        });
    }
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
            match a {
                Action::Start => {
                    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis();
                    let wav = shepetal::new_recording(&data_home, stamp).map_err(|e| format!("audio file: {e}"))?;
                    rec = Some((record(&wav).map_err(|e| format!("recorder: {e}"))?, wav));
                }
                Action::Cancel => {
                    if let Some((c, wav)) = rec.take() {
                        stop(c);
                        if let Err(e) = shepetal::mark_cancelled(&wav) {
                            eprintln!("shepetal: mark cancelled {}: {e}", wav.display());
                        }
                    }
                }
                Action::Stop => {
                    let Some((c, wav)) = rec.take() else { continue };
                    stop(c);
                    // ponytail: transcribes on the input thread, so keys pressed meanwhile queue up.
                    // The WAV stays in the audio history: it is exactly what the model heard.
                    match transcribe(&model, &wav) {
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
        }
    }
}
