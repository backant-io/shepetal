//! The daemon's end of the 🤫 indicator: a Unix socket, `$XDG_RUNTIME_DIR/shepetal.sock`
//! (mode 0600), that sends one line per change to every connected indicator, and the current
//! state to each one that connects. Lines:
//!
//! - `idle`, `recording`, `handsfree`, `processing`: the ring around 🤫
//! - `error <text>`: yellow ring, the text next to 🤫 for about 4 s
//! - `hint <text>`: the text next to 🤫 for about 2 s, the ring unchanged
//!
//! Readers: `linux/indicator/shepetal-indicator` (X11, wlr-layer-shell) and the GNOME Shell
//! extension in `linux/gnome-extension/`.

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
            return Err(std::io::Error::other("another shepetal daemon is running"));
        }
        let _ = std::fs::remove_file(path);
        let listener = UnixListener::bind(path)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        let shared = Arc::new(Mutex::new(Shared { state: "idle".into(), clients: vec![] }));
        let s = shared.clone();
        std::thread::spawn(move || {
            for c in listener.incoming().flatten() {
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
    fn a_running_daemon_keeps_its_socket_and_a_dead_ones_is_replaced() {
        let (dir, _ind, _r) = bound("twice");
        let sock = dir.join("shepetal.sock");
        let err = Indicator::bind(&sock).err().expect("a second daemon must not start");
        assert_eq!(err.to_string(), "another shepetal daemon is running");

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
