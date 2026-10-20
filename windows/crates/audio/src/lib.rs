//! shepetal for Windows: the microphone, the kept-audio store and local speech-to-text.
//!
//! One dictation: `Mic::start`, `Mic::stop` (16 kHz mono f32), `Store::save` (every clip is
//! kept, goal rule 4), then `transcribe` with a `Whisper` loaded from `model::ensure`.

mod mic;
pub mod model;
mod resample;
mod store;
mod stt;
pub mod wav;

pub use mic::Mic;
pub use resample::{resample, RATE};
pub use store::{data_dir, Kind, Retention, Store};
pub use stt::{no_audio, transcribe, Stt, SttError, Whisper};
