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
/// keeps exiting within 30 s. Waiting on it also reaps it, so no zombie is left. A program that is
/// not installed is reported once, then looked for again with the same backoff, so installing it
/// later brings 🤫 up without a daemon restart.
pub fn supervise(program: String, delay: Duration) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut sup = Supervisor::new(delay);
        loop {
            let started = Instant::now();
            let run = start(&program, crate::insert::on_path);
            let (wait, log) = sup.next(&program, run, started.elapsed());
            if let Some(l) = log {
                eprintln!("shepetal: 🤫 {l}");
            }
            std::thread::sleep(wait);
        }
    })
}

/// How one start of the indicator ended.
#[derive(Debug, PartialEq)]
enum Run {
    /// Not on PATH, or its interpreter is not: nothing ran.
    Missing,
    /// It ran and exited (or could not be waited on); the status or error, for the log.
    Exited(String),
}

/// Start `program` and wait for it. Checked with `installed` (on PATH) first: Rust 1.75 (Ubuntu
/// 24.04) spawns a missing program as a child that exits 127 instead of returning an error (#130).
fn start(program: &str, installed: impl Fn(&str) -> bool) -> Run {
    if !installed(program) {
        return Run::Missing;
    }
    match Command::new(program).spawn().and_then(|mut c| c.wait()) {
        // `env` exits 127 when the script's interpreter (python3) is missing.
        Ok(s) if s.code() == Some(127) => Run::Missing,
        Ok(s) => Run::Exited(s.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Run::Missing,
        Err(e) => Run::Exited(e.to_string()),
    }
}

/// The supervisor's backoff and what it logs, apart from processes and time so tests can feed it.
struct Supervisor {
    delay: Duration,
    wait: Duration,
    /// Said that it is missing, and not since seen it run: say nothing more until it runs.
    told_missing: bool,
}

impl Supervisor {
    fn new(delay: Duration) -> Supervisor {
        Supervisor { delay, wait: delay, told_missing: false }
    }

    /// After a start that ended as `run` after `ran_for`: how long to wait before the next start,
    /// and the line to log, if any.
    fn next(&mut self, program: &str, run: Run, ran_for: Duration) -> (Duration, Option<String>) {
        let log = match run {
            Run::Missing if self.told_missing => None,
            Run::Missing => {
                self.told_missing = true;
                Some(format!("indicator not started: {program}: not installed, or python3 is missing (see docs/linux.md); looking for it again every {:?} at most", self.delay * 32))
            }
            Run::Exited(how) => {
                self.told_missing = false;
                if ran_for >= Duration::from_secs(30) {
                    self.wait = self.delay;
                }
                Some(format!("indicator exited ({how}); starting it again in {:?}", self.wait))
            }
        };
        let wait = self.wait;
        self.wait = (self.wait * 2).min(self.delay * 32);
        (wait, log)
    }
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
        let dir = std::env::temp_dir().join(format!("shepetal-sup-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let prog = fake_program(&dir, "fake-indicator", &format!("echo started >> '{}/runs'\nexit 1", dir.display()));
        let _ = supervise(prog.display().to_string(), Duration::from_millis(10));
        let runs = || std::fs::read_to_string(dir.join("runs")).map_or(0, |s| s.lines().count());
        let t = Instant::now();
        while runs() < 3 && t.elapsed() < Duration::from_secs(5) {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(runs() >= 3, "started {} times", runs());
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn fake_program(dir: &Path, name: &str, body: &str) -> PathBuf {
        let p = dir.join(name);
        std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o700)).unwrap();
        p
    }

    #[test]
    fn a_missing_indicator_is_looked_up_on_path_and_never_spawned() {
        // #130: on Rust 1.75 spawning a missing program "succeeds" and the child exits 127, so
        // the PATH check has to come first. `installed` says no here, and the program, which
        // exists, must not run.
        let dir = std::env::temp_dir().join(format!("shepetal-start-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let ran = dir.join("ran");
        let prog = fake_program(&dir, "fake-indicator", &format!("touch '{}'\nexit 3", ran.display()));
        let p = prog.to_str().unwrap();
        assert_eq!(start(p, |_| false), Run::Missing);
        assert!(!ran.exists(), "a program not on PATH was spawned");
        assert_eq!(start(p, |_| true), Run::Exited("exit status: 3".into()));
        assert!(ran.exists());

        // Real lookups: a name on no PATH dir, an absolute path that is not there, and a script
        // whose interpreter is missing (`env` exits 127).
        let no_python = dir.join("no-python");
        std::fs::write(&no_python, "#!/usr/bin/env shepetal-no-such-python\n").unwrap();
        std::fs::set_permissions(&no_python, std::fs::Permissions::from_mode(0o700)).unwrap();
        for prog in ["shepetal-no-such-indicator", dir.join("missing").to_str().unwrap(), no_python.to_str().unwrap()] {
            assert_eq!(start(prog, crate::insert::on_path), Run::Missing, "{prog}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_missing_indicator_is_reported_once_and_looked_for_with_backoff() {
        let s = Duration::from_secs;
        let mut sup = Supervisor::new(s(2));
        let mut logs = vec![];
        let mut waits = vec![];
        for _ in 0..8 {
            let (wait, log) = sup.next("shepetal-indicator", Run::Missing, Duration::ZERO);
            waits.push(wait.as_secs());
            logs.extend(log);
        }
        assert_eq!(waits, [2, 4, 8, 16, 32, 64, 64, 64], "backs off to 64 s, never stops looking");
        assert_eq!(logs.len(), 1, "said once, not every round: {logs:?}");
        assert!(logs[0].contains("shepetal-indicator: not installed"), "{}", logs[0]);

        // Installed later: it runs, and it is reported if it goes missing again.
        let (wait, log) = sup.next("shepetal-indicator", Run::Exited("exit status: 1".into()), s(31));
        assert_eq!((wait, log.unwrap()), (s(2), "indicator exited (exit status: 1); starting it again in 2s".into()), "a run over 30 s resets the wait");
        let (_, log) = sup.next("shepetal-indicator", Run::Missing, Duration::ZERO);
        assert!(log.is_some(), "missing again after it ran is said again");
        assert_eq!(sup.next("shepetal-indicator", Run::Missing, Duration::ZERO).1, None);
    }

    #[test]
    fn an_indicator_that_keeps_crashing_backs_off_and_one_that_ran_long_restarts_soon() {
        let ms = Duration::from_millis;
        let mut sup = Supervisor::new(ms(100));
        let crash = |sup: &mut Supervisor, ran: u64| sup.next("i", Run::Exited("signal: 11".into()), ms(ran)).0.as_millis();
        let waits: Vec<_> = (0..7).map(|_| crash(&mut sup, 50)).collect();
        assert_eq!(waits, [100, 200, 400, 800, 1600, 3200, 3200]);
        assert_eq!(crash(&mut sup, 29_999), 3200, "under 30 s keeps the backoff");
        assert_eq!(crash(&mut sup, 30_000), 100, "30 s or more starts over");
        assert_eq!(crash(&mut sup, 10), 200);
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
