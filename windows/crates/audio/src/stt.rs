//! Local speech-to-text. Goal rule 5: it runs on the device, and nothing here opens a network
//! connection (the model is fetched before, by `model::ensure`).

use std::path::Path;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperState};

/// A speech-to-text engine: 16 kHz mono samples in, raw text out.
pub trait Stt {
    fn run(&mut self, samples: &[f32]) -> Result<String, String>;
}

#[derive(Debug, PartialEq)]
pub enum SttError {
    /// Every sample is exactly zero: the mic delivered nothing (muted, blocked or unplugged).
    NoAudio,
    Engine(String),
}

/// True only when every sample is exactly zero. A quiet but working mic is still audio.
pub fn no_audio(samples: &[f32]) -> bool {
    samples.iter().all(|&s| s == 0.0)
}

/// Transcribe one clip: refuse an all-zero clip without running the model, drop whisper's
/// non-speech markers (`[BLANK_AUDIO]`, `[Music]`) and collapse whitespace.
pub fn transcribe(stt: &mut dyn Stt, samples: &[f32]) -> Result<String, SttError> {
    if no_audio(samples) {
        return Err(SttError::NoAudio);
    }
    let raw = stt.run(samples).map_err(SttError::Engine)?;
    Ok(clean(&raw))
}

/// Without whisper's markers, whitespace collapsed.
fn clean(raw: &str) -> String {
    without_markers(raw).split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Below this RMS a 20 ms frame is silence: -50 dBFS, under quiet speech and over most mic hiss.
// ponytail: one fixed floor; calibrate it on real meeting mics if quiet speech goes missing.
const FLOOR: f32 = 0.003_16;
const FRAME: usize = 320;
/// A pause under 1 s stays inside the stretch, and 200 ms of lead-in and tail are kept.
const GAP: usize = 16_000;
const PAD: usize = 3_200;

/// The stretches of a 16 kHz channel that hold sound, as sample ranges.
fn speech(samples: &[f32]) -> Vec<std::ops::Range<usize>> {
    let mut out: Vec<std::ops::Range<usize>> = vec![];
    for (i, f) in samples.chunks(FRAME).enumerate() {
        if (f.iter().map(|s| s * s).sum::<f32>() / f.len() as f32).sqrt() < FLOOR {
            continue;
        }
        let r = (i * FRAME).saturating_sub(PAD)..(i * FRAME + f.len() + PAD).min(samples.len());
        match out.last_mut() {
            Some(last) if r.start <= last.end + GAP => last.end = r.end,
            _ => out.push(r),
        }
    }
    out
}

/// One meeting segment: whisper's start (centiseconds) in ms and its clean text, or None when
/// only markers were left.
fn timed(t0_cs: i64, raw: &str) -> Option<(u64, String)> {
    Some((t0_cs.max(0) as u64 * 10, clean(raw))).filter(|(_, t)| !t.is_empty())
}

/// Text between brackets is a marker. An `[` that is never closed is kept as text. Same rule
/// as the Linux daemon's `without_markers`.
fn without_markers(s: &str) -> String {
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

/// whisper.cpp through whisper-rs: CPU by default, the GPU when built with the `cuda` feature.
pub struct Whisper {
    state: WhisperState,
    multilingual: bool,
}

impl Whisper {
    /// Load a ggml model file from disk.
    pub fn load(model: &Path) -> Result<Whisper, String> {
        // whisper.cpp logs every load step to stderr; errors still come back as Results.
        whisper_rs::install_logging_hooks();
        let ctx = WhisperContext::new_with_params(model, WhisperContextParameters::default())
            .map_err(|e| hide("Could not load the speech model. Delete it to download it again.", e))?;
        let multilingual = ctx.is_multilingual();
        let state = ctx.create_state().map_err(|e| hide("Could not start the speech model.", e))?;
        Ok(Whisper { state, multilingual })
    }

    /// A whole 16 kHz meeting channel: each segment's start (ms into it) and text. Each stretch
    /// of speech runs on its own from its exact offset, because over a whole channel whisper's
    /// times leave out the silences (while the other side talks), so Me and Others would not
    /// interleave. Silence never reaches the model.
    pub fn segments(&mut self, samples: &[f32]) -> Result<Vec<(u64, String)>, String> {
        let mut out = vec![];
        for r in speech(samples) {
            self.full(&samples[r.clone()])?;
            let at = r.start as u64 * 1000 / crate::RATE as u64;
            for seg in self.state.as_iter() {
                let text = seg.to_str_lossy().map_err(|e| hide("Speech recognition failed.", e))?;
                out.extend(timed(seg.start_timestamp(), &text).map(|(t, x)| (at + t, x)));
            }
        }
        Ok(out)
    }

    fn full(&mut self, samples: &[f32]) -> Result<(), String> {
        let mut p = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        // An English-only model is told so; a multilingual one detects the language per clip.
        p.set_language(Some(if self.multilingual { "auto" } else { "en" }));
        let threads = std::thread::available_parallelism().map_or(4, |n| n.get().min(8));
        p.set_n_threads(threads as _);
        p.set_no_context(true);
        p.set_print_progress(false);
        p.set_print_realtime(false);
        p.set_print_special(false);
        p.set_print_timestamps(false);
        self.state.full(p, samples).map_err(|e| hide("Speech recognition failed.", e))
    }
}

impl Stt for Whisper {
    fn run(&mut self, samples: &[f32]) -> Result<String, String> {
        self.full(samples)?;
        let mut text = String::new();
        for seg in self.state.as_iter() {
            text.push_str(&seg.to_str_lossy().map_err(|e| hide("Speech recognition failed.", e))?);
        }
        Ok(text)
    }
}

/// The user sees `msg`; whisper-rs's own text names the engine, so it goes to the log only.
fn hide(msg: &str, e: whisper_rs::WhisperError) -> String {
    eprintln!("shepetal: speech-to-text: {e}");
    msg.into()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Records what it heard and answers with a fixed text.
    struct Fake {
        heard: Vec<Vec<f32>>,
        says: Result<String, String>,
    }

    impl Stt for Fake {
        fn run(&mut self, samples: &[f32]) -> Result<String, String> {
            self.heard.push(samples.to_vec());
            self.says.clone()
        }
    }

    fn fake(says: Result<&str, &str>) -> Fake {
        Fake { heard: vec![], says: says.map(String::from).map_err(String::from) }
    }

    #[test]
    fn the_engine_hears_exactly_the_clip() {
        let mut f = fake(Ok(" Hello world."));
        let clip = [0.1, -0.2, 0.0];
        assert_eq!(transcribe(&mut f, &clip), Ok("Hello world.".into()));
        assert_eq!(f.heard, [clip.to_vec()]);
    }

    #[test]
    fn markers_are_not_typed_at_the_cursor() {
        let mut f = fake(Ok(" [BLANK_AUDIO]\n Hello\n  world. [Music]\n"));
        assert_eq!(transcribe(&mut f, &[0.1]), Ok("Hello world.".into()));
        let mut f = fake(Ok("[BLANK_AUDIO]"));
        assert_eq!(transcribe(&mut f, &[0.1]), Ok(String::new()));
        let mut f = fake(Ok("a [ b"));
        assert_eq!(transcribe(&mut f, &[0.1]), Ok("a [ b".into()), "an unclosed [ is text");
    }

    #[test]
    fn only_all_zero_audio_is_no_audio() {
        // A quiet mic must not be reported as missing: one tiny sample is enough.
        let mut f = fake(Ok("hi"));
        assert_eq!(transcribe(&mut f, &[0.0, 1e-7, 0.0]), Ok("hi".into()));
        assert_eq!(transcribe(&mut f, &[0.0, -0.0, 0.0]), Err(SttError::NoAudio));
        assert_eq!(transcribe(&mut f, &[]), Err(SttError::NoAudio));
        assert_eq!(f.heard.len(), 1, "the model never runs on no audio");
    }

    #[test]
    fn a_broken_model_file_error_never_names_the_model() {
        // whisper-rs errors say "whisper"; the app shows this text, and the UI names no model.
        let p = std::env::temp_dir().join(format!("shepetal-stt-{}-junk.bin", std::process::id()));
        std::fs::write(&p, b"not a model").unwrap();
        let err = Whisper::load(&p).err().unwrap().to_lowercase();
        assert!(err.contains("speech model"), "{err}");
        for name in ["whisper", "ggml", "junk.bin"] {
            assert!(!err.contains(name), "{err}");
        }
    }

    #[test]
    fn meeting_segments_keep_their_start_and_drop_markers() {
        // whisper counts in centiseconds; the transcript's times are ms into the meeting.
        assert_eq!(timed(372_345, "  Yes. [Music]  Loud and clear.\n"), Some((3_723_450, "Yes. Loud and clear.".into())));
        assert_eq!(timed(248, " [BLANK_AUDIO]"), None, "a marker alone is no turn");
        assert_eq!(timed(0, " Hi"), Some((0, "Hi".into())));
    }

    #[test]
    fn a_channel_splits_into_its_stretches_of_speech() {
        let sec = |s: f32| (s * 16_000.0) as usize;
        let tone = |secs: f32, amp: f32| (0..sec(secs)).map(move |i| amp * (i as f32 * 0.07).sin());
        let quiet = |secs: f32| std::iter::repeat_n(0.0005, sec(secs)); // -66 dBFS hiss
        // Me says something, is quiet for 3 s while the others talk, then answers softly (-45 dBFS).
        let me: Vec<f32> = tone(1.0, 0.1).chain(quiet(3.0)).chain(tone(0.5, 0.008)).chain(quiet(0.6)).chain(tone(0.5, 0.1)).chain(quiet(2.0)).collect();
        // Each stretch starts 200 ms before its sound, so its times count from the real offset.
        assert_eq!(speech(&me), [0..sec(1.2), sec(3.8)..sec(5.8)], "a 0.6 s pause stays inside the answer");
        assert_eq!(speech(&quiet(10.0).collect::<Vec<_>>()), [], "hiss alone never reaches the model");
        assert_eq!(speech(&[0.0; 16_000]), [], "the silence padded into Others.wav");
    }

    #[test]
    fn engine_errors_come_back() {
        let mut f = fake(Err("boom"));
        assert_eq!(transcribe(&mut f, &[0.1]), Err(SttError::Engine("boom".into())));
    }
}
