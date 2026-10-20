//! End to end on real speech: espeak-ng speaks a sentence, and it takes the dictation path
//! (resample to 16 kHz, keep it in the store, read the kept file back, whisper.cpp on the CPU
//! model). Needs espeak-ng on PATH and SHEPETAL_MODELS, a folder that holds the CPU model or
//! where it is downloaded to. Run it without a network to show transcription needs none:
//!
//!   docker run --network none ... SHEPETAL_MODELS=/models cargo test -p audio --test e2e -- --ignored

use std::path::Path;
use std::process::Command;

const SENTENCE: &str = "The quick brown fox jumps over the lazy dog.";

#[test]
#[ignore = "needs espeak-ng and the CPU speech model, see the top of tests/e2e.rs"]
fn synthesized_speech_is_transcribed_on_the_device() {
    let models = std::env::var_os("SHEPETAL_MODELS").expect("set SHEPETAL_MODELS");
    let model = audio::model::ensure(Path::new(&models), &audio::model::CPU).unwrap();

    let dir = std::env::temp_dir().join(format!("shepetal-e2e-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let tts = dir.join("tts.wav");
    let spoke = Command::new("espeak-ng").args(["-v", "en-us", "-w"]).arg(&tts).arg(SENTENCE).status().unwrap();
    assert!(spoke.success());
    let (samples, rate) = audio::wav::read(&tts).unwrap();
    assert_ne!(rate, audio::RATE, "espeak-ng speaks at 22.05 kHz, so the resampler is on the path");

    let clip = audio::resample(&samples, rate, audio::RATE);
    let kept = audio::Store::open(dir.join("audio")).unwrap().save(1, audio::Kind::Dictation, &clip).unwrap();
    let (heard, kept_rate) = audio::wav::read(&kept).unwrap();
    assert_eq!((kept_rate, heard.len()), (16_000, clip.len()));
    // whisper still reads slowed-down speech, so check the speed here: the kept clip must play
    // back as long as it was spoken.
    let secs = |n: usize, rate: u32| n as f64 / rate as f64;
    assert!((secs(heard.len(), kept_rate) - secs(samples.len(), rate)).abs() < 0.01, "kept clip changed speed");

    let mut stt = audio::Whisper::load(&model).unwrap();
    let t = std::time::Instant::now();
    let text = audio::transcribe(&mut stt, &heard).unwrap();
    eprintln!("{:.1} s of speech -> {:?} in {:?}", heard.len() as f32 / 16_000.0, text, t.elapsed());
    let words: Vec<String> = text.split_whitespace().map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase()).collect();
    for w in ["quick", "brown", "fox", "jumps", "over", "lazy", "dog"] {
        assert!(words.iter().any(|x| x == w), "{w:?} missing from {text:?}");
    }
}
