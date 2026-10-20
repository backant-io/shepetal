//! Mic frames to the 16 kHz mono f32 the speech model takes.

use cpal::{FromSample, Sample};
use std::f64::consts::PI;

/// The rate of every kept clip and of what the model hears.
pub const RATE: u32 = 16_000;

/// Zero crossings of the sinc on each side of an output sample.
const ZEROS: f64 = 16.0;

/// Interleaved frames of any sample type to mono f32, averaging the channels.
pub(crate) fn downmix<T: Sample>(frames: &[T], channels: usize) -> impl Iterator<Item = f32> + '_
where
    f32: FromSample<T>,
{
    let ch = channels.max(1);
    frames.chunks_exact(ch).map(move |f| f.iter().map(|s| f32::from_sample(*s)).sum::<f32>() / ch as f32)
}

/// Resample mono `x` from `from` Hz to `to` Hz with a Hann-windowed sinc. Going down, it cuts at the
/// new Nyquist frequency, so a 48 kHz mic's sound above 8 kHz is removed instead of folding back
/// into the speech band. Positions are exact integers (polyphase), so long clips do not drift.
pub fn resample(x: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || x.is_empty() {
        return x.to_vec();
    }
    let g = gcd(from, to);
    // Output i sits at input position i * down / up.
    let (up, down) = ((to / g) as usize, (from / g) as usize);
    let cutoff = (to as f64 / from as f64).min(1.0);
    let half = (ZEROS / cutoff).ceil() as usize;
    let taps = 2 * half;
    // kernel[p * taps + j]: the weight of input c + 1 - half + j for an output at c + p / up.
    let kernel: Vec<f32> = (0..up)
        .flat_map(|p| {
            (0..taps).map(move |j| {
                let d = p as f64 / up as f64 + half as f64 - 1.0 - j as f64;
                let window = 0.5 + 0.5 * (PI * d / half as f64).cos();
                (cutoff * sinc(cutoff * d) * window) as f32
            })
        })
        .collect();
    let n = x.len() * up / down;
    (0..n)
        .map(|i| {
            let (c, p) = (i * down / up, i * down % up);
            let w = &kernel[p * taps..][..taps];
            let start = (c + 1) as isize - half as isize;
            w.iter()
                .enumerate()
                .filter_map(|(j, w)| x.get(usize::try_from(start + j as isize).ok()?).map(|s| s * w))
                .sum()
        })
        .collect()
}

fn sinc(x: f64) -> f64 {
    if x == 0.0 {
        1.0
    } else {
        (PI * x).sin() / (PI * x)
    }
}

fn gcd(a: u32, b: u32) -> u32 {
    if b == 0 {
        a
    } else {
        gcd(b, a % b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(hz: f64, rate: u32, secs: f64) -> Vec<f32> {
        (0..(rate as f64 * secs) as usize).map(|i| (2.0 * PI * hz * i as f64 / rate as f64).sin() as f32 * 0.5).collect()
    }

    fn rms(x: &[f32]) -> f32 {
        (x.iter().map(|s| s * s).sum::<f32>() / x.len() as f32).sqrt()
    }

    #[test]
    fn every_common_mic_rate_lands_on_16k_with_the_same_length_in_time() {
        for rate in [8_000, 16_000, 22_050, 44_100, 48_000, 96_000] {
            assert_eq!(resample(&vec![0.1; rate as usize], rate, RATE).len(), 16_000, "{rate} Hz, 1 s");
        }
    }

    #[test]
    fn speech_band_tone_comes_out_as_the_same_tone_at_16k() {
        // A 1 kHz tone resampled must equal a 1 kHz tone generated at 16 kHz, in phase and level.
        // A wrong position (drift, off by one sample) or gain fails this.
        let want = tone(1000.0, RATE, 1.0);
        for rate in [8_000, 44_100, 48_000] {
            let got = resample(&tone(1000.0, rate, 1.0), rate, RATE);
            let err = got[800..15_200].iter().zip(&want[800..15_200]).map(|(a, b)| (a - b).abs()).fold(0.0, f32::max);
            assert!(err < 0.01, "{rate} Hz: max error {err}");
        }
    }

    #[test]
    fn sound_above_8khz_is_filtered_out_not_folded_into_speech() {
        // Plain decimation of a 48 kHz mic turns a 10 kHz whine into a full-level 6 kHz tone.
        for rate in [44_100, 48_000] {
            let got = resample(&tone(10_000.0, rate, 1.0), rate, RATE);
            assert!(rms(&got[800..15_200]) < 0.005, "{rate} Hz: {}", rms(&got[800..15_200]));
        }
    }

    #[test]
    fn same_rate_is_untouched() {
        let x = tone(440.0, RATE, 0.1);
        assert_eq!(resample(&x, RATE, RATE), x);
    }

    #[test]
    fn downmix_averages_channels_and_scales_integers() {
        assert_eq!(downmix(&[1.0f32, 0.0, 0.5, 0.5], 2).collect::<Vec<_>>(), [0.5, 0.5]);
        assert_eq!(downmix(&[i16::MIN, 0, 16_384], 1).collect::<Vec<_>>(), [-1.0, 0.0, 0.5]);
        assert_eq!(downmix(&[0u16, 32_768], 1).collect::<Vec<_>>(), [-1.0, 0.0], "u16 is offset by 32768");
    }
}
