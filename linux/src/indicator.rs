//! The daemon's end of the 🤫 indicator: a Unix socket, `$XDG_RUNTIME_DIR/shepetal.sock`
//! (mode 0600), that sends one line per change to every connected indicator, and the current
//! state to each one that connects. Lines:
//!
//! - `idle`, `recording`, `handsfree`, `processing`: the ring around 🤫
//! - `error <text>`: yellow ring, the text next to 🤫 for about 4 s
//! - `hint <text>`: the text next to 🤫 for about 3 s, the ring unchanged
//!
//! Readers: `linux/indicator/shepetal-indicator` (X11, wlr-layer-shell) and the GNOME Shell
//! extension in `linux/gnome-extension/`.

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::process::Command;
use std::time::{Duration, Instant};

struct Shared {
    /// The last state line, sent to an indicator when it connects. Text is not replayed.
    state: String,
    clients: Vec<UnixStream>,
}

/// Cheap to clone. The default has no socket and drops every line.
#[derive(Clone, Default)]
pub struct Indicator(Option<Arc<Mutex<Shared>>>);

/// `$XDG_RUNTIME_DIR/shepetal.sock`, if the runtime dir is set and private (no group or other
/// bits), as the XDG Base Directory spec requires.
pub fn socket_path(runtime_dir: Option<&str>) -> Option<PathBuf> {
    let dir = Path::new(runtime_dir.filter(|d| d.starts_with('/'))?);
    let md = std::fs::metadata(dir).ok()?;
    (md.is_dir() && md.permissions().mode() & 0o077 == 0).then(|| dir.join("shepetal.sock"))
}

impl Indicator {
    /// Listen on `path`. A socket left by a daemon that died is replaced; one that answers
    /// belongs to a running daemon, and two daemons would both record on every fn press.
    pub fn bind(path: &Path) -> std::io::Result<Indicator> {
        if UnixStream::connect(path).is_ok() {
            return Err(std::io::Error::new(std::io::ErrorKind::AddrInUse, "another shepetal daemon is running"));
        }
        let _ = std::fs::remove_file(path);
        let listener = UnixListener::bind(path)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        let shared = Arc::new(Mutex::new(Shared { state: "idle".into(), clients: vec![] }));
        let s = shared.clone();
        std::thread::spawn(move || {
            for c in listener.incoming() {
                let Ok(c) = c else {
                    // E.g. out of file descriptors: wait instead of spinning a core.
                    std::thread::sleep(Duration::from_millis(100));
                    continue;
                };
                // A reader that stops reading must not stall the dictation loop.
                let _ = c.set_write_timeout(Some(Duration::from_millis(100)));
                let mut g = s.lock().unwrap();
                if writeln!(&c, "{}", g.state).is_ok() {
                    g.clients.push(c);
                }
            }
        });
        Ok(Indicator(Some(shared)))
    }

    /// Send one line to every indicator, and drop the ones that are gone.
    pub fn send(&self, line: &str) {
        let Some(s) = &self.0 else { return };
        // A newline in the text would start a second line, e.g. a state.
        let line = line.replace(['\n', '\r'], " ");
        let mut g = s.lock().unwrap();
        let word = line.split(' ').next().unwrap_or_default();
        if word != "hint" {
            g.state = word.to_string();
        }
        g.clients.retain(|c| writeln!(&*c, "{line}").is_ok());
    }
}

/// Keep the indicator program running for as long as the daemon runs (goal rule 3: 🤫 is always
/// there): start it, and when it exits (a crash, an X server or compositor restart, a display that
/// was not ready yet) start it again after `delay`. The delay doubles, up to 32 times, while it
/// keeps exiting within 30 s. Waiting on it also reaps it, so no zombie is left. A program that
/// cannot be started at all (not installed) is reported once and not retried.
pub fn supervise(program: String, delay: Duration) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut wait = delay;
        loop {
            let started = Instant::now();
            let status = match Command::new(&program).spawn() {
                Ok(mut child) => child.wait(),
                Err(e) => {
                    eprintln!("shepetal: 🤫 indicator not started: {program}: {e} (see docs/linux.md)");
                    return;
                }
            };
            // 127 is "not found" too: `env` exits with it when the script's interpreter (python3)
            // is missing, and some systems report a missing program that way instead of an error.
            if status.as_ref().is_ok_and(|s| s.code() == Some(127)) {
                eprintln!("shepetal: 🤫 indicator not started: {program}: not found (see docs/linux.md)");
                return;
            }
            if started.elapsed() >= Duration::from_secs(30) {
                wait = delay;
            }
            let how = status.map_or_else(|e| e.to_string(), |s| s.to_string());
            eprintln!("shepetal: 🤫 indicator exited ({how}); starting it again in {wait:?}");
            std::thread::sleep(wait);
            wait = (wait * 2).min(delay * 32);
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};

    /// A private runtime dir with a bound indicator, and a reader connected to it.
    fn bound(tag: &str) -> (PathBuf, Indicator, BufReader<UnixStream>) {
        use std::os::unix::fs::DirBuilderExt;
        let dir = std::env::temp_dir().join(format!("shepetal-rt-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
        let sock = socket_path(dir.to_str()).unwrap();
        let ind = Indicator::bind(&sock).unwrap();
        let reader = BufReader::new(UnixStream::connect(&sock).unwrap());
        (dir, ind, reader)
    }

    fn line(r: &mut BufReader<UnixStream>) -> String {
        r.get_ref().set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut s = String::new();
        r.read_line(&mut s).unwrap();
        s
    }

    #[test]
    fn socket_is_owner_only_in_a_private_runtime_dir() {
        let (dir, _ind, _r) = bound("mode");
        let mode = std::fs::metadata(dir.join("shepetal.sock")).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "other users must not read what shepetal is doing");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(socket_path(dir.to_str()), None, "a runtime dir others can enter is refused");
        assert_eq!(socket_path(Some("relative")), None);
        assert_eq!(socket_path(None), None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn every_indicator_gets_the_state_and_late_ones_the_current_one() {
        let (dir, ind, mut first) = bound("late");
        assert_eq!(line(&mut first), "idle\n", "a new indicator starts from the current state");
        ind.send("recording");
        assert_eq!(line(&mut first), "recording\n");

        // An indicator started mid-dictation (or restarted) shows the ring at once.
        let mut late = BufReader::new(UnixStream::connect(dir.join("shepetal.sock")).unwrap());
        assert_eq!(line(&mut late), "recording\n");

        ind.send("hint Hold fn to talk\nprocessing");
        assert_eq!(line(&mut first), "hint Hold fn to talk processing\n", "text cannot inject a line");
        assert_eq!(line(&mut late), "hint Hold fn to talk processing\n");

        // A hint is not a state: an indicator that connects after it still shows recording.
        // An error's text is not replayed either, only its yellow ring.
        let mut after_hint = BufReader::new(UnixStream::connect(dir.join("shepetal.sock")).unwrap());
        assert_eq!(line(&mut after_hint), "recording\n");
        ind.send("error Transcription failed");
        let mut after_error = BufReader::new(UnixStream::connect(dir.join("shepetal.sock")).unwrap());
        assert_eq!(line(&mut after_error), "error\n");

        drop(late); // a closed indicator is dropped, the others still get lines
        ind.send("idle");
        ind.send("idle");
        assert_eq!(line(&mut first), "error Transcription failed\n");
        assert_eq!(line(&mut first), "idle\n");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_reader_that_never_reads_cannot_stall_the_daemon() {
        let (dir, ind, stuck) = bound("stuck");
        let mut live = BufReader::new(UnixStream::connect(dir.join("shepetal.sock")).unwrap());
        assert_eq!(line(&mut live), "idle\n");
        // Enough to fill any socket buffer many times over; `stuck` never reads.
        let (tx, rx) = std::sync::mpsc::channel();
        let sender = ind.clone();
        std::thread::spawn(move || {
            let text = "x".repeat(1000);
            for _ in 0..3000 {
                sender.send(&format!("hint {text}"));
            }
            sender.send("recording");
            tx.send(()).unwrap();
        });
        rx.recv_timeout(Duration::from_secs(10)).expect("send blocked on a reader that does not read");
        drop(stuck);
        // `live` read nothing meanwhile either, so it was dropped too; a new reader still works.
        let mut fresh = BufReader::new(UnixStream::connect(dir.join("shepetal.sock")).unwrap());
        assert_eq!(line(&mut fresh), "recording\n");
        ind.send("idle");
        assert_eq!(line(&mut fresh), "idle\n");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_indicator_is_started_again_when_it_exits() {
        // Goal rule 3: a crashed indicator comes back while the daemon runs.
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("shepetal-sup-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let prog = dir.join("fake-indicator");
        std::fs::write(&prog, format!("#!/bin/sh\necho started >> '{}/runs'\nexit 1\n", dir.display())).unwrap();
        std::fs::set_permissions(&prog, std::fs::Permissions::from_mode(0o700)).unwrap();
        let _ = supervise(prog.display().to_string(), Duration::from_millis(10));
        let runs = || std::fs::read_to_string(dir.join("runs")).map_or(0, |s| s.lines().count());
        let t = Instant::now();
        while runs() < 3 && t.elapsed() < Duration::from_secs(5) {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(runs() >= 3, "started {} times", runs());

        // Not installed, or its interpreter is not (`env` exits 127): reported once, and the
        // supervisor ends instead of retrying forever.
        let no_python = dir.join("no-python");
        std::fs::write(&no_python, "#!/usr/bin/env shepetal-no-such-python\n").unwrap();
        std::fs::set_permissions(&no_python, std::fs::Permissions::from_mode(0o700)).unwrap();
        for prog in [dir.join("missing"), no_python] {
            let h = supervise(prog.display().to_string(), Duration::from_millis(10));
            let t = Instant::now();
            while !h.is_finished() && t.elapsed() < Duration::from_secs(5) {
                std::thread::sleep(Duration::from_millis(10));
            }
            assert!(h.is_finished(), "{} is retried", prog.display());
        }
    }

    #[test]
    fn a_running_daemon_keeps_its_socket_and_a_dead_ones_is_replaced() {
        let (dir, _ind, _r) = bound("twice");
        let sock = dir.join("shepetal.sock");
        let err = Indicator::bind(&sock).err().expect("a second daemon must not start");
        assert_eq!(err.to_string(), "another shepetal daemon is running");
        assert_eq!(err.kind(), std::io::ErrorKind::AddrInUse);

        let stale = dir.join("stale.sock");
        // A socket file nobody accepts on. Not a dropped UnixListener: a test in another thread
        // that forks a tool between our bind and drop would keep that listener alive in the child
        // until exec, and the connect would succeed.
        drop(std::os::unix::net::UnixDatagram::bind(&stale).unwrap());
        let ind = Indicator::bind(&stale).expect("a dead daemon's socket is replaced");
        let mut r = BufReader::new(UnixStream::connect(&stale).unwrap());
        assert_eq!(line(&mut r), "idle\n"); // read first: the accept thread may not have run yet
        ind.send("recording");
        assert_eq!(line(&mut r), "recording\n");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
