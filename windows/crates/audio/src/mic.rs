//! The default microphone through cpal (WASAPI on Windows), with a pre-roll so the first
//! syllable, spoken as the key goes down, is kept.

use crate::resample::{downmix, resample, RATE};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SampleFormat, SizedSample};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Mono samples at the mic's own rate: a ring of the last `cap` samples while idle, and the
/// whole clip (pre-roll first) while recording.
pub(crate) struct Recorder {
    pre: VecDeque<f32>,
    cap: usize,
    clip: Option<Vec<f32>>,
}

impl Recorder {
    pub(crate) fn new(cap: usize) -> Self {
        Recorder { pre: VecDeque::with_capacity(cap + 1), cap, clip: None }
    }

    pub(crate) fn push(&mut self, mono: impl Iterator<Item = f32>) {
        match &mut self.clip {
            Some(clip) => clip.extend(mono),
            None => {
                for s in mono {
                    self.pre.push_back(s);
                    if self.pre.len() > self.cap {
                        self.pre.pop_front();
                    }
                }
            }
        }
    }

    /// Start a clip with the pre-roll in front. A second start while recording keeps the clip.
    pub(crate) fn start(&mut self) {
        if self.clip.is_none() {
            self.clip = Some(self.pre.drain(..).collect());
        }
    }

    /// End the clip and return it. The pre-roll starts over, so the next clip never repeats
    /// the end of this one.
    pub(crate) fn stop(&mut self) -> Vec<f32> {
        self.clip.take().unwrap_or_default()
    }
}

/// The default input device, open and running. Samples flow into the pre-roll for as long as
/// this lives, so keep one `Mic` open while shepetal runs (Windows then shows the mic as in use).
pub struct Mic {
    _stream: cpal::Stream,
    rec: Arc<Mutex<Recorder>>,
    rate: u32,
}

impl Mic {
    /// Open the default microphone, keeping `pre_roll` of audio before each `start` (about
    /// 300 ms holds a syllable spoken as the key goes down).
    pub fn open(pre_roll: Duration) -> Result<Mic, String> {
        let device = cpal::default_host().default_input_device().ok_or("No microphone found")?;
        let supported = device.default_input_config().map_err(|e| format!("Microphone: {e}"))?;
        let config = supported.config();
        let rate = config.sample_rate;
        let cap = (rate as u128 * pre_roll.as_millis() / 1000) as usize;
        let rec = Arc::new(Mutex::new(Recorder::new(cap)));
        let r = rec.clone();
        let stream = match supported.sample_format() {
            SampleFormat::F32 => build::<f32>(&device, config, r),
            SampleFormat::I16 => build::<i16>(&device, config, r),
            SampleFormat::I32 => build::<i32>(&device, config, r),
            SampleFormat::U16 => build::<u16>(&device, config, r),
            f => return Err(format!("Microphone sample format {f} is not supported")),
        }
        .map_err(|e| format!("Microphone: {e}"))?;
        stream.play().map_err(|e| format!("Microphone: {e}"))?;
        Ok(Mic { _stream: stream, rec, rate })
    }

    /// Begin a clip, seeded with the pre-roll.
    pub fn start(&self) {
        self.rec.lock().unwrap().start();
    }

    /// End the clip and return it as 16 kHz mono f32, ready for the model and the store.
    pub fn stop(&self) -> Vec<f32> {
        let raw = self.rec.lock().unwrap().stop();
        resample(&raw, self.rate, RATE)
    }
}

fn build<T>(device: &cpal::Device, config: cpal::StreamConfig, rec: Arc<Mutex<Recorder>>) -> Result<cpal::Stream, cpal::Error>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    let channels = config.channels as usize;
    device.build_input_stream(
        config,
        move |data: &[T], _: &cpal::InputCallbackInfo| rec.lock().unwrap().push(downmix(data, channels)),
        |e| eprintln!("shepetal: microphone: {e}"),
        None,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn push(r: &mut Recorder, xs: &[f32]) {
        r.push(xs.iter().copied());
    }

    #[test]
    fn first_syllable_before_the_key_is_kept() {
        // The pre-roll holds the last `cap` samples before start, oldest dropped first.
        let mut r = Recorder::new(3);
        push(&mut r, &[1.0, 2.0, 3.0, 4.0, 5.0]);
        r.start();
        push(&mut r, &[6.0, 7.0, 8.0, 9.0]);
        assert_eq!(r.stop(), [3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0], "a clip is not capped by the pre-roll");
    }

    #[test]
    fn next_clip_never_repeats_the_last_one() {
        let mut r = Recorder::new(3);
        push(&mut r, &[0.5]);
        r.start();
        push(&mut r, &[1.0, 2.0]);
        assert_eq!(r.stop(), [0.5, 1.0, 2.0]);
        push(&mut r, &[3.0]);
        r.start();
        push(&mut r, &[4.0]);
        assert_eq!(r.stop(), [3.0, 4.0]);
    }

    #[test]
    fn a_second_start_does_not_drop_the_clip() {
        // Hands-free double-taps can start twice; rule 4 keeps every sample.
        let mut r = Recorder::new(2);
        push(&mut r, &[1.0]);
        r.start();
        push(&mut r, &[2.0]);
        r.start();
        push(&mut r, &[3.0]);
        assert_eq!(r.stop(), [1.0, 2.0, 3.0]);
    }

    #[test]
    fn no_pre_roll_and_stop_without_start() {
        let mut r = Recorder::new(0);
        push(&mut r, &[1.0, 2.0]);
        assert!(r.stop().is_empty());
        r.start();
        push(&mut r, &[3.0]);
        assert_eq!(r.stop(), [3.0]);
    }
}
