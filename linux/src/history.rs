//! Dictation history (F52) and the retention policy (F53, goal rule 4).
//!
//! One JSON object per line in `<data_home>/shepetal/history.jsonl` (0600, in the 0700 shepetal
//! dir), next to the kept audio in `<data_home>/shepetal/audio/`. Every recording gets a line:
//! inserted, left on the clipboard, too short, cancelled, failed, or no speech. The outcome names
//! match the Mac's `ShepetalCore/History.swift`, so a later sync can merge both.
//!
//! Retention is `keep` (the default) or `delete_after_24h`, read from
//! `$XDG_CONFIG_HOME/shepetal/config.json` (`{"retention": "delete_after_24h"}`). With 24 h, the
//! daemon deletes older recordings and their history lines at start and then every hour.

use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    /// Unix ms when the recording started; also the audio file's stem.
    pub id: u128,
    /// `inserted`, `paste_failed` (the text was left on the clipboard), `too_short`, `cancelled`,
    /// `failed` (speech-to-text error) or `no_speech` (the model heard no words).
    pub outcome: String,
    /// The kept WAV, absolute.
    pub audio: PathBuf,
    pub duration_ms: u64,
    pub model: String,
    pub text: String,
}

pub const OUTCOMES: [&str; 6] = ["inserted", "paste_failed", "too_short", "cancelled", "failed", "no_speech"];

pub fn dir(data_home: &Path) -> PathBuf {
    data_home.join("shepetal")
}

fn file(data_home: &Path) -> PathBuf {
    dir(data_home).join("history.jsonl")
}

/// Length of a 16 kHz mono s16 WAV with a 44-byte header, from its size.
pub fn wav_duration_ms(wav: &Path) -> u64 {
    std::fs::metadata(wav).map_or(0, |m| m.len().saturating_sub(44) / 32)
}

impl Entry {
    fn to_json(&self) -> Value {
        json!({"id": self.id.to_string(), "outcome": self.outcome, "audio": self.audio,
               "duration_ms": self.duration_ms, "model": self.model, "text": self.text})
    }

    fn from_json(v: &Value) -> Option<Entry> {
        Some(Entry {
            id: v["id"].as_str()?.parse().ok()?,
            outcome: v["outcome"].as_str()?.to_string(),
            audio: PathBuf::from(v["audio"].as_str()?),
            duration_ms: v["duration_ms"].as_u64().unwrap_or(0),
            model: v["model"].as_str().unwrap_or_default().to_string(),
            text: v["text"].as_str().unwrap_or_default().to_string(),
        })
    }
}

/// Open the history file for writing, creating it 0600. Refuses one that is not a regular file
/// owned by this user and closed to others (a symlink planted there, or a mode someone widened).
fn open(path: &Path, append: bool) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
    // The shepetal dir is 0700, so only this user could plant a link; refuse one anyway.
    if std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(std::io::Error::other(format!("{} is a symlink", path.display())));
    }
    let f = std::fs::OpenOptions::new().create(true).write(true).append(append).truncate(!append)
        .mode(0o600).open(path)?;
    let md = f.metadata()?;
    let me = std::fs::metadata(dir_of(path))?.uid();
    if !md.is_file() || md.uid() != me || md.permissions().mode() & 0o077 != 0 {
        return Err(std::io::Error::other(format!("{} must be a 0600 file of this user", path.display())));
    }
    Ok(f)
}

fn dir_of(path: &Path) -> &Path {
    path.parent().unwrap_or(Path::new("/"))
}

/// Append one entry.
pub fn append(data_home: &Path, e: &Entry) -> std::io::Result<()> {
    let mut f = open(&file(data_home), true)?;
    // One write per line, so a reader never sees half a line.
    f.write_all(format!("{}\n", e.to_json()).as_bytes())
}

/// Every entry, oldest first. Lines that do not parse are skipped.
pub fn load(data_home: &Path) -> Vec<Entry> {
    let Ok(s) = std::fs::read_to_string(file(data_home)) else { return vec![] };
    s.lines().filter_map(|l| serde_json::from_str(l).ok()).filter_map(|v| Entry::from_json(&v)).collect()
}

/// Write `entries` as the whole history, through a temp file renamed over the old one.
pub fn save(data_home: &Path, entries: &[Entry]) -> std::io::Result<()> {
    let tmp = dir(data_home).join("history.jsonl.new");
    let _ = std::fs::remove_file(&tmp);
    let mut f = open(&tmp, false)?;
    for e in entries {
        f.write_all(format!("{}\n", e.to_json()).as_bytes())?;
    }
    f.sync_all()?;
    std::fs::rename(tmp, file(data_home))
}

/// Entries whose text contains every word of `query`, ignoring case, newest first.
pub fn search<'a>(entries: &'a [Entry], query: &str) -> Vec<&'a Entry> {
    let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
    entries.iter().rev().filter(|e| {
        let t = e.text.to_lowercase();
        words.iter().all(|w| t.contains(w.as_str()))
    }).collect()
}

/// The newest entry with text: what paste-last and copy-last use (F21).
pub fn last_text(entries: &[Entry]) -> Option<&Entry> {
    entries.iter().rev().find(|e| !e.text.is_empty())
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Retention {
    Keep,
    Delete24h,
}

/// The retention in `config.json` text. A missing, unreadable or unknown value keeps everything:
/// deleting audio the user wanted kept cannot be undone.
pub fn retention(config_json: Option<&str>) -> Retention {
    let v: Value = config_json.and_then(|s| serde_json::from_str(s).ok()).unwrap_or_default();
    match v["retention"].as_str() {
        Some("delete_after_24h") => Retention::Delete24h,
        _ => Retention::Keep,
    }
}

pub fn config_file(config_home: &Path) -> PathBuf {
    config_home.join("shepetal").join("config.json")
}

const DAY_MS: u128 = 24 * 3600 * 1000;

/// With `Delete24h`, delete every recording that started 24 h or more before `now_ms`: its audio
/// file (any outcome) and its history line. Returns the deleted audio files.
pub fn apply_retention(data_home: &Path, r: Retention, now_ms: u128) -> std::io::Result<Vec<PathBuf>> {
    if r == Retention::Keep {
        return Ok(vec![]);
    }
    let old = |stamp: u128| stamp + DAY_MS <= now_ms;
    let mut deleted = vec![];
    // Audio files by their stem, so a clip without a history line (the daemon was killed) goes too.
    if let Ok(rd) = std::fs::read_dir(dir(data_home).join("audio")) {
        for p in rd.flatten().map(|e| e.path()) {
            let stamp = p.file_name().and_then(|n| n.to_str()).and_then(|n| n.split('.').next()).and_then(|s| s.parse().ok());
            if stamp.is_some_and(old) && std::fs::remove_file(&p).is_ok() {
                deleted.push(p);
            }
        }
    }
    let entries = load(data_home);
    if entries.iter().any(|e| old(e.id)) {
        let kept: Vec<_> = entries.into_iter().filter(|e| !old(e.id)).collect();
        save(data_home, &kept)?;
    }
    deleted.sort();
    Ok(deleted)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn home(tag: &str) -> PathBuf {
        let h = std::env::temp_dir().join(format!("shepetal-hist-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&h);
        h
    }

    fn entry(id: u128, outcome: &str, text: &str, h: &Path) -> Entry {
        Entry { id, outcome: outcome.into(), audio: h.join(format!("shepetal/audio/{id}.wav")), duration_ms: 1500, model: "parakeet".into(), text: text.into() }
    }

    #[test]
    fn entries_round_trip_in_an_owner_only_file() {
        let h = home("trip");
        let wav = crate::new_recording(&h, 1).unwrap(); // makes the 0700 dirs
        let e1 = Entry { audio: wav, ..entry(1, "inserted", "Hello \"world\"\nagain", &h) };
        let e2 = entry(2, "too_short", "", &h);
        append(&h, &e1).unwrap();
        append(&h, &e2).unwrap();
        assert_eq!(load(&h), [e1, e2]);
        let mode = std::fs::metadata(h.join("shepetal/history.jsonl")).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        std::fs::set_permissions(h.join("shepetal/history.jsonl"), std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(append(&h, &entry(3, "inserted", "x", &h)).is_err(), "a history file others can read is refused");
        std::fs::remove_dir_all(&h).unwrap();
    }

    #[test]
    fn a_symlink_in_place_of_the_history_is_refused() {
        let h = home("link");
        crate::new_recording(&h, 1).unwrap();
        let target = h.join("elsewhere");
        std::fs::write(&target, "").unwrap();
        std::os::unix::fs::symlink(&target, h.join("shepetal/history.jsonl")).unwrap();
        assert!(append(&h, &entry(1, "inserted", "secret", &h)).is_err());
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "", "nothing written through the link");
        std::fs::remove_dir_all(&h).unwrap();
    }

    #[test]
    fn search_finds_every_word_ignoring_case_newest_first() {
        let h = home("search");
        let es = [entry(1, "inserted", "Schedule the Review", &h), entry(2, "inserted", "ÜBER review notes", &h),
                  entry(3, "paste_failed", "review the schedule", &h), entry(4, "too_short", "", &h)];
        let ids = |q| search(&es, q).iter().map(|e| e.id).collect::<Vec<_>>();
        assert_eq!(ids("review"), [3, 2, 1]);
        assert_eq!(ids("schedule REVIEW"), [3, 1]);
        assert_eq!(ids("über"), [2], "non-ASCII case folding");
        assert_eq!(ids("missing"), Vec::<u128>::new());
        assert_eq!(last_text(&es).map(|e| e.id), Some(3), "skips the too-short entry with no text");
        assert_eq!(last_text(&[]), None);
    }

    #[test]
    fn retention_defaults_to_keep() {
        assert_eq!(retention(None), Retention::Keep);
        assert_eq!(retention(Some("not json")), Retention::Keep);
        assert_eq!(retention(Some(r#"{"retention": "never_store"}"#)), Retention::Keep, "there is no never-store option");
        assert_eq!(retention(Some(r#"{"retention": "keep"}"#)), Retention::Keep);
        assert_eq!(retention(Some(r#"{"retention": "delete_after_24h"}"#)), Retention::Delete24h);
    }

    #[test]
    fn delete_after_24h_removes_old_audio_and_lines_on_time() {
        let h = home("ret");
        let now: u128 = 1_800_000_000_000;
        let ids = [now - DAY_MS - 1, now - DAY_MS, now - DAY_MS + 1, now - 5];
        let audio = h.join("shepetal/audio");
        for (i, id) in ids.iter().enumerate() {
            let wav = crate::new_recording(&h, *id).unwrap();
            let wav = if i == 0 { crate::mark(&wav, "cancelled").unwrap() } else { wav };
            append(&h, &Entry { audio: wav, ..entry(*id, if i == 0 { "cancelled" } else { "inserted" }, "t", &h) }).unwrap();
        }
        let orphan = crate::new_recording(&h, now - 2 * DAY_MS).unwrap(); // no history line

        assert_eq!(apply_retention(&h, Retention::Keep, now).unwrap(), Vec::<PathBuf>::new());
        assert_eq!(std::fs::read_dir(&audio).unwrap().count(), 5, "keep deletes nothing");

        let gone = apply_retention(&h, Retention::Delete24h, now).unwrap();
        let mut want = vec![audio.join(format!("{}.cancelled.wav", ids[0])), audio.join(format!("{}.wav", ids[1])), orphan];
        want.sort();
        assert_eq!(gone, want, "24 h old and older, every outcome, also without a history line");
        assert_eq!(load(&h).iter().map(|e| e.id).collect::<Vec<_>>(), &ids[2..], "their history lines are gone too");
        let mode = std::fs::metadata(h.join("shepetal/history.jsonl")).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "the rewritten history is still owner-only");
        std::fs::remove_dir_all(&h).unwrap();
    }

    #[test]
    fn duration_comes_from_the_wav_size() {
        let h = home("dur");
        let wav = crate::new_recording(&h, 1).unwrap();
        std::fs::write(&wav, vec![0u8; 44 + 32000]).unwrap();
        assert_eq!(wav_duration_ms(&wav), 1000);
        assert_eq!(wav_duration_ms(&h.join("missing.wav")), 0);
        std::fs::remove_dir_all(&h).unwrap();
    }
}
