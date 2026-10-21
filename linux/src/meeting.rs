//! Meeting detection: which other apps are using the mic or the camera right now (from `pw-dump`
//! JSON and /proc), and which monitor source carries the system audio. Any app counts. Only
//! shepetal's own processes never do, and those are told apart by pid, never by name.

use serde_json::Value;
use std::path::Path;

/// An app using the mic or the camera.
#[derive(Debug, Clone, PartialEq)]
pub struct Stream {
    /// `application.name`, else the binary or process name. Empty when nothing names it.
    pub app: String,
    pub pid: Option<u32>,
}

fn props(obj: &Value) -> &Value {
    &obj["info"]["props"]
}

fn str_of<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}

fn nodes(objs: &[Value]) -> impl Iterator<Item = &Value> {
    objs.iter().filter(|o| str_of(o, "type") == "PipeWire:Interface:Node")
}

fn running(o: &Value) -> bool {
    str_of(&o["info"], "state") == "running"
}

/// Who owns a node. A pipewire-pulse stream (parecord, browsers) carries its app's pid itself. A
/// native one (pw-record) carries only `client.id`, and the pid is on that Client object.
fn who(objs: &[Value], node: &Value) -> Stream {
    let p = props(node);
    let client = p["client.id"].as_u64().and_then(|id| {
        objs.iter().find(|o| o["id"].as_u64() == Some(id) && str_of(o, "type") == "PipeWire:Interface:Client")
    });
    let get = |k: &str| [Some(p), client.map(props)].into_iter().flatten().map(|v| &v[k]).find(|v| !v.is_null());
    let text = |k: &str| get(k).and_then(Value::as_str).filter(|s| !s.is_empty());
    let pid = get("application.process.id").and_then(|v| v.as_u64().or_else(|| v.as_str()?.parse().ok())).and_then(|n| u32::try_from(n).ok());
    let app = text("application.name").or(text("application.process.binary")).unwrap_or("").to_string();
    Stream { app, pid }
}

fn not_ours<'a>(own: &'a [u32]) -> impl Fn(&Stream) -> bool + 'a {
    move |s| !s.pid.is_some_and(|p| own.contains(&p))
}

/// Running mic captures (not sink monitors) of processes not in `own`.
pub fn mic_streams(dump: &Value, own: &[u32]) -> Vec<Stream> {
    let Some(objs) = dump.as_array() else { return vec![] };
    nodes(objs)
        .filter(|o| running(o) && str_of(props(o), "media.class") == "Stream/Input/Audio")
        // A stream recording a sink monitor is capturing system audio, not the mic.
        .filter(|o| props(o)["stream.capture.sink"].as_bool() != Some(true)
            && props(o)["stream.capture.sink"].as_str() != Some("true"))
        .map(|o| who(objs, o))
        .filter(not_ours(own))
        .collect()
}

/// Apps on a running PipeWire camera: the nodes linked to it. A running camera with no link
/// shows as one unnamed user. Screencasts are not cameras (they are Stream/Output/Video).
fn camera_streams(dump: &Value, own: &[u32]) -> Vec<Stream> {
    let Some(objs) = dump.as_array() else { return vec![] };
    let mut out = vec![];
    for cam in nodes(objs).filter(|o| running(o)) {
        let p = props(cam);
        let Some(id) = cam["id"].as_u64() else { continue };
        if str_of(p, "media.class") != "Video/Source" && str_of(p, "media.role") != "Camera" {
            continue;
        }
        let users: Vec<_> = objs.iter()
            .filter(|l| str_of(l, "type") == "PipeWire:Interface:Link" && l["info"]["output-node-id"].as_u64() == Some(id))
            .filter_map(|l| {
                let input = l["info"]["input-node-id"].as_u64()?;
                nodes(objs).find(|n| n["id"].as_u64() == Some(input))
            })
            .map(|n| who(objs, n))
            .collect();
        if users.is_empty() {
            out.push(Stream { app: String::new(), pid: None });
        }
        out.extend(users.into_iter().filter(not_ours(own)));
    }
    out
}

/// Processes under `proc` (/proc) other than `own` that have a /dev/video* open: the apps that
/// use a camera directly through V4L2, as Zoom and most browsers do, past PipeWire. Only the
/// user's own processes are readable, which is all a meeting app can be.
fn video_holders(proc: &Path, own: &[u32]) -> Vec<Stream> {
    let Ok(dir) = std::fs::read_dir(proc) else { return vec![] };
    let mut out: Vec<_> = dir.flatten()
        .filter_map(|e| e.file_name().to_str()?.parse::<u32>().ok())
        .filter(|pid| !own.contains(pid))
        .filter(|pid| std::fs::read_dir(proc.join(pid.to_string()).join("fd")).into_iter().flatten().flatten()
            .any(|fd| std::fs::read_link(fd.path()).is_ok_and(|t| t.to_string_lossy().starts_with("/dev/video"))))
        .map(|pid| Stream {
            app: std::fs::read_to_string(proc.join(pid.to_string()).join("comm")).unwrap_or_default().trim().to_string(),
            pid: Some(pid),
        })
        .collect();
    out.sort_by_key(|s| s.pid);
    out
}

/// The apps using a camera: those PipeWire sees, else the /dev/video* holders.
/// ponytail: while PipeWire serves a camera, its own process holds /dev/video* too, so PipeWire's
/// answer wins. For the few seconds before WirePlumber suspends a camera nobody uses any more, the
/// fallback can still see PipeWire on it and the end comes that much later.
pub fn camera_users(dump: &Value, proc: &Path, own: &[u32]) -> Vec<Stream> {
    let cam = camera_streams(dump, own);
    if cam.is_empty() { video_holders(proc, own) } else { cam }
}

/// `me` and its children under `proc`: the daemon and the recorders it runs (dictation, Me.wav,
/// Others.wav). Exact by pid, so another app named shepetal or pw-record still counts.
pub fn own_pids(proc: &Path, me: u32) -> Vec<u32> {
    let mut own = vec![me];
    for e in std::fs::read_dir(proc).into_iter().flatten().flatten() {
        let Some(pid) = e.file_name().to_str().and_then(|n| n.parse::<u32>().ok()) else { continue };
        let status = std::fs::read_to_string(e.path().join("status")).unwrap_or_default();
        let ppid = status.lines().find_map(|l| l.strip_prefix("PPid:")).and_then(|v| v.trim().parse::<u32>().ok());
        if ppid == Some(me) {
            own.push(pid);
        }
    }
    own
}

/// The default sink's monitor source name, as used by `parecord --device=` / `pw-record --target`.
pub fn system_audio_source(dump: &Value) -> Option<String> {
    let objs = dump.as_array()?;
    let meta = objs.iter().find(|o| {
        str_of(o, "type") == "PipeWire:Interface:Metadata" && str_of(props(o), "metadata.name") == "default"
    })?;
    let entry = meta["metadata"].as_array()?.iter().find(|e| str_of(e, "key") == "default.audio.sink")?;
    // value is either {"name": ...} or that object serialized as a string.
    let v = &entry["value"];
    let name = match v.as_str() {
        Some(s) => serde_json::from_str::<Value>(s).ok()?["name"].as_str()?.to_string(),
        None => v["name"].as_str()?.to_string(),
    };
    Some(format!("{name}.monitor"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Value {
        serde_json::from_str(include_str!("../fixtures/pw-dump-meeting.json")).unwrap()
    }

    fn apps(s: &[Stream]) -> Vec<&str> {
        s.iter().map(|s| s.app.as_str()).collect()
    }

    /// The fixture's shepetal recorder: pw-record, whose pid is only on its Client object.
    const OURS: u32 = 9001;

    #[test]
    fn any_app_on_the_mic_counts_but_idle_streams_monitors_and_playback_do_not() {
        // Fixture also has: Discord idle, OBS capturing the sink monitor, Chrome and Zoom
        // playback, and a hardware source node. A sound recorder is no meeting app, but any
        // mic use is a possible meeting now.
        let s = mic_streams(&fixture(), &[OURS]);
        assert_eq!(apps(&s), ["ZOOM VoiceEngine", "Firefox", "GNOME Sound Recorder"]);
        assert_eq!(s[0].pid, Some(4211));
    }

    #[test]
    fn ours_is_by_pid_never_by_name() {
        // The fixture's own recorder is named shepetal. If its pid is not ours (another user's
        // or an old daemon), it is another app on the mic like any other.
        let s = mic_streams(&fixture(), &[]);
        assert_eq!(apps(&s), ["ZOOM VoiceEngine", "Firefox", "GNOME Sound Recorder", "shepetal"]);
        assert_eq!(s[3].pid, Some(OURS), "the pid comes from the node's client");
        // Captured from real PipeWire 1.0.5 (Ubuntu 24.04): pw-record with -P application.name =
        // shepetal (pid on the client only) and parecord through pipewire-pulse (pid on the node).
        let real: Value = serde_json::from_str(include_str!("../fixtures/pw-dump-own-recorders.json")).unwrap();
        assert_eq!(mic_streams(&real, &[4160, 4161]), [], "both recorders are ours by pid");
        let theirs = mic_streams(&real, &[4160]);
        assert_eq!(theirs, [Stream { app: "shepetal".into(), pid: Some(4161) }]);
        // pipewire.sec.pid of a pulse client is pipewire-pulse's: never taken as the app's.
        assert_eq!(mic_streams(&real, &[4149]).len(), 2);
    }

    #[test]
    fn a_camera_counts_only_while_an_app_has_it_running() {
        // Firefox is linked to the running v4l2 camera. The libcamera one is suspended, and OBS
        // on gnome-shell's screencast is a video stream but no camera.
        let s = camera_streams(&fixture(), &[OURS]);
        assert_eq!(s, [Stream { app: "Firefox".into(), pid: Some(3120) }]);
        assert!(!format!("{s:?}").contains("Weekly sync"), "a media.name (a tab title) is never kept");

        // A running camera whose user PipeWire does not show still counts, unnamed.
        let mut d = fixture();
        d.as_array_mut().unwrap().retain(|o| o["id"] != 152);
        assert_eq!(camera_streams(&d, &[]), [Stream { app: String::new(), pid: None }]);
        // And a camera only shepetal held would not (it never opens one).
        assert_eq!(camera_streams(&fixture(), &[OURS, 3120]), []);
    }

    /// A fake /proc: (pid, comm, ppid, fd targets).
    fn proc(name: &str, procs: &[(u32, &str, u32, &[&str])]) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("shepetal-proc-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        for (pid, comm, ppid, fds) in procs {
            let p = d.join(pid.to_string());
            std::fs::create_dir_all(p.join("fd")).unwrap();
            std::fs::write(p.join("comm"), format!("{comm}\n")).unwrap();
            std::fs::write(p.join("status"), format!("Name:\t{comm}\nPid:\t{pid}\nPPid:\t{ppid}\n")).unwrap();
            for (i, t) in fds.iter().enumerate() {
                std::os::unix::fs::symlink(t, p.join("fd").join(i.to_string())).unwrap();
            }
        }
        std::fs::create_dir_all(d.join("self")).unwrap(); // not a pid, skipped
        d
    }

    #[test]
    fn video_device_holders_are_the_camera_fallback() {
        let d = proc("video", &[
            (100, "shepetal", 1, &["/dev/input/event3"]),
            (200, "zoom", 1, &["/dev/null", "socket:[123]", "/dev/video0"]),
            (300, "firefox", 1, &["/dev/snd/pcmC0D0c"]),
            (400, "pw-record", 100, &["/dev/video2"]),
            (500, "cheese", 1, &["/dev/video1"]),
        ]);
        let own = own_pids(&d, 100);
        let mut sorted = own.clone();
        sorted.sort();
        assert_eq!(sorted, [100, 400], "the daemon and its recorder");
        assert_eq!(video_holders(&d, &own), [
            Stream { app: "zoom".into(), pid: Some(200) },
            Stream { app: "cheese".into(), pid: Some(500) },
        ]);
        // No camera in PipeWire: the holders. A running PipeWire camera: its users, and the
        // holders (PipeWire's own process among them) are not asked.
        assert_eq!(apps(&camera_users(&serde_json::json!([]), &d, &own)), ["zoom", "cheese"]);
        assert_eq!(apps(&camera_users(&fixture(), &d, &own)), ["Firefox"]);
        std::fs::remove_dir_all(&d).unwrap();
        assert_eq!(video_holders(&d, &[]), [], "no /proc, no holders");
        assert_eq!(own_pids(&d, 7), [7]);
    }

    #[test]
    fn system_audio_is_default_sink_monitor() {
        assert_eq!(
            system_audio_source(&fixture()).as_deref(),
            Some("alsa_output.pci-0000_00_1f.3.analog-stereo.monitor")
        );
    }

    #[test]
    fn garbage_dump_is_empty_not_a_panic() {
        assert!(mic_streams(&Value::Null, &[]).is_empty());
        assert!(camera_streams(&Value::Null, &[]).is_empty());
        assert_eq!(system_audio_source(&serde_json::json!([{}])), None);
    }
}
