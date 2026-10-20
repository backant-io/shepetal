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
    Ok(without_markers(&raw).split_whitespace().collect::<Vec<_>>().join(" "))
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
            .map_err(|e| format!("Could not load the speech model: {e}"))?;
        let multilingual = ctx.is_multilingual();
        let state = ctx.create_state().map_err(|e| format!("Could not start the speech model: {e}"))?;
        Ok(Whisper { state, multilingual })
    }
}

impl Stt for Whisper {
    fn run(&mut self, samples: &[f32]) -> Result<String, String> {
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
        self.state.full(p, samples).map_err(|e| format!("Speech recognition failed: {e}"))?;
        let mut text = String::new();
        for seg in self.state.as_iter() {
            text.push_str(&seg.to_str_lossy().map_err(|e| format!("Speech recognition failed: {e}"))?);
        }
        Ok(text)
    }
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
    fn engine_errors_come_back() {
        let mut f = fake(Err("boom"));
        assert_eq!(transcribe(&mut f, &[0.1]), Err(SttError::Engine("boom".into())));
    }
}
