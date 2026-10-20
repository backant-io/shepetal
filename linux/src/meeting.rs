//! Meeting detection over `pw-dump` JSON: which apps are capturing the mic right now,
//! and which monitor source carries the system audio.

use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
pub struct Stream {
    pub app: String,
    pub binary: String,
    /// Known meeting app this stream belongs to, if any.
    pub meeting: Option<&'static str>,
}

/// (needle in application.name / process.binary, lowercased) -> display name.
/// Browsers count because PipeWire cannot see the tab; a browser on the mic is most likely a Meet call.
const MEETING_APPS: &[(&str, &str)] = &[
    ("zoom", "Zoom"),
    ("teams", "Microsoft Teams"),
    ("slack", "Slack"),
    ("discord", "Discord"),
    ("chrom", "Browser (Chrome/Chromium)"),
    ("firefox", "Browser (Firefox)"),
];

fn props(obj: &Value) -> &Value {
    &obj["info"]["props"]
}

fn str_of<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}

/// Application streams that are actively capturing an input (not a sink monitor).
pub fn mic_streams(dump: &Value) -> Vec<Stream> {
    let Some(objs) = dump.as_array() else { return vec![] };
    objs.iter()
        .filter(|o| str_of(o, "type") == "PipeWire:Interface:Node")
        .filter(|o| str_of(&o["info"], "state") == "running")
        .filter(|o| str_of(props(o), "media.class") == "Stream/Input/Audio")
        // A stream recording a sink monitor is capturing system audio, not the mic.
        .filter(|o| props(o)["stream.capture.sink"].as_bool() != Some(true)
            && props(o)["stream.capture.sink"].as_str() != Some("true"))
        .map(|o| {
            let p = props(o);
            let app = str_of(p, "application.name").to_string();
            let binary = str_of(p, "application.process.binary").to_string();
            let hay = format!("{app} {binary}").to_lowercase();
            let meeting = MEETING_APPS.iter().find(|(n, _)| hay.contains(n)).map(|(_, d)| *d);
            Stream { app, binary, meeting }
        })
        .filter(|s| s.app != "shepetal")
        .collect()
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

    #[test]
    fn finds_meeting_apps_on_the_mic() {
        let s = mic_streams(&fixture());
        let meetings: Vec<_> = s.iter().filter_map(|s| s.meeting).collect();
        assert_eq!(meetings, vec!["Zoom", "Browser (Firefox)"]);
    }

    #[test]
    fn ignores_idle_streams_monitors_playback_and_itself() {
        // Fixture also has: Discord idle, OBS capturing the sink monitor, Chrome playback,
        // a hardware source node, and shepetal's own pw-record. Only the two above plus
        // the non-meeting recorder may remain.
        let s = mic_streams(&fixture());
        let apps: Vec<_> = s.iter().map(|s| s.app.as_str()).collect();
        assert_eq!(apps, vec!["ZOOM VoiceEngine", "Firefox", "GNOME Sound Recorder"]);
        assert_eq!(s[2].meeting, None);
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
        assert!(mic_streams(&Value::Null).is_empty());
        assert_eq!(system_audio_source(&serde_json::json!([{}])), None);
    }
}
