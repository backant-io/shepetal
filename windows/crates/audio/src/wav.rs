//! WAV files: the kept clips (32-bit float mono, the exact samples the model heard) and, for
//! re-transcribing, any 16-bit PCM or 32-bit float WAV.

use std::io::{self, Write};
use std::path::Path;

/// Write `samples` as a 32-bit float mono WAV (format 3, with the `fact` chunk the spec asks
/// for on non-PCM data), so no sample is rounded to 16 bits.
pub fn write(mut w: impl Write, samples: &[f32], rate: u32) -> io::Result<()> {
    let data = u32::try_from(samples.len() * 4)
        .ok()
        .filter(|d| *d <= u32::MAX - 50)
        .ok_or_else(|| bad("recording too long for one WAV file"))?;
    let mut b = Vec::with_capacity(58 + data as usize);
    b.extend(b"RIFF");
    b.extend((50 + data).to_le_bytes());
    b.extend(b"WAVEfmt ");
    b.extend(18u32.to_le_bytes());
    b.extend(3u16.to_le_bytes()); // WAVE_FORMAT_IEEE_FLOAT
    b.extend(1u16.to_le_bytes()); // mono
    b.extend(rate.to_le_bytes());
    b.extend((rate * 4).to_le_bytes()); // bytes per second
    b.extend(4u16.to_le_bytes()); // bytes per frame
    b.extend(32u16.to_le_bytes()); // bits per sample
    b.extend(0u16.to_le_bytes()); // no extension
    b.extend(b"fact");
    b.extend(4u32.to_le_bytes());
    b.extend((samples.len() as u32).to_le_bytes());
    b.extend(b"data");
    b.extend(data.to_le_bytes());
    for s in samples {
        b.extend(s.to_le_bytes());
    }
    w.write_all(&b)?;
    w.flush()
}

/// Read a 16-bit PCM or 32-bit float WAV as mono f32 (channels averaged) and its sample rate.
pub fn read(path: &Path) -> io::Result<(Vec<f32>, u32)> {
    let b = std::fs::read(path)?;
    if b.len() < 12 || &b[0..4] != b"RIFF" || &b[8..12] != b"WAVE" {
        return Err(bad("not a WAV file"));
    }
    let le16 = |c: &[u8], o: usize| u16::from_le_bytes([c[o], c[o + 1]]);
    let le32 = |c: &[u8], o: usize| u32::from_le_bytes([c[o], c[o + 1], c[o + 2], c[o + 3]]);
    let mut fmt = None;
    let mut i = 12;
    while i + 8 <= b.len() {
        let len = le32(&b, i + 4) as usize;
        let body = &b[i + 8..(i + 8).saturating_add(len).min(b.len())];
        match &b[i..i + 4] {
            b"fmt " if body.len() >= 16 => fmt = Some((le16(body, 0), le16(body, 2), le32(body, 4), le16(body, 14))),
            b"data" => {
                let (tag, channels, rate, bits) = fmt.ok_or_else(|| bad("WAV data before its format"))?;
                let samples: Vec<f32> = match (tag, bits) {
                    (1, 16) => body.as_chunks().0.iter().map(|s| i16::from_le_bytes(*s) as f32 / 32768.0).collect(),
                    (3, 32) => body.as_chunks().0.iter().map(|s| f32::from_le_bytes(*s)).collect(),
                    _ => return Err(bad("unsupported WAV encoding")),
                };
                return Ok((crate::resample::downmix(&samples, channels as usize).collect(), rate));
            }
            _ => {}
        }
        // Chunks are padded to an even length.
        i = i.saturating_add(8 + len + (len & 1));
    }
    Err(bad("WAV file has no audio"))
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("shepetal-wav-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d.join("x.wav")
    }

    #[test]
    fn kept_clip_reads_back_bit_for_bit() {
        // Goal rule 4: the file holds the exact samples the model received, not a 16-bit copy.
        let samples = [0.0, 1e-7, -0.333_333_34, 1.0, -1.0, 0.123_456_79];
        let p = tmp("roundtrip");
        write(std::fs::File::create(&p).unwrap(), &samples, 16_000).unwrap();
        let (got, rate) = read(&p).unwrap();
        assert_eq!(rate, 16_000);
        assert_eq!(got.iter().map(|s| s.to_bits()).collect::<Vec<_>>(), samples.map(f32::to_bits));
    }

    #[test]
    fn header_is_a_standard_float_mono_wav_other_players_open() {
        // History replays the clip, so every field another reader checks must be right, not
        // only the ones our own reader uses.
        let mut b = Vec::new();
        write(&mut b, &[0.5; 10], 16_000).unwrap();
        let u16at = |o: usize| u16::from_le_bytes([b[o], b[o + 1]]);
        let u32at = |o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap());
        assert_eq!(b.len(), 58 + 40);
        assert_eq!((&b[0..4], u32at(4) as usize, &b[8..16]), (&b"RIFF"[..], b.len() - 8, &b"WAVEfmt "[..]));
        assert_eq!((u32at(16), u16at(20), u16at(22)), (18, 3, 1), "fmt size, IEEE float, mono");
        assert_eq!((u32at(24), u32at(28), u16at(32), u16at(34)), (16_000, 64_000, 4, 32));
        assert_eq!((&b[38..42], u32at(46)), (&b"fact"[..], 10), "frame count");
        assert_eq!((&b[50..54], u32at(54)), (&b"data"[..], 40));
    }

    #[test]
    fn reads_16_bit_pcm_stereo_and_skips_unknown_chunks() {
        // What ffmpeg or a TTS tool writes: a LIST chunk (odd length, so padded) before data.
        let mut b = b"RIFF\0\0\0\0WAVEfmt ".to_vec();
        b.extend(16u32.to_le_bytes());
        for v in [1u16, 2] {
            b.extend(v.to_le_bytes()); // PCM, stereo
        }
        b.extend(22_050u32.to_le_bytes());
        b.extend((22_050u32 * 4).to_le_bytes());
        b.extend(4u16.to_le_bytes());
        b.extend(16u16.to_le_bytes());
        b.extend(b"LIST");
        b.extend(3u32.to_le_bytes());
        b.extend(b"abc\0"); // 3 bytes plus the pad byte
        b.extend(b"data");
        b.extend(8u32.to_le_bytes());
        for v in [16_384i16, 0, -32_768, -32_768] {
            b.extend(v.to_le_bytes());
        }
        let p = tmp("pcm16");
        std::fs::write(&p, &b).unwrap();
        assert_eq!(read(&p).unwrap(), (vec![0.25, -1.0], 22_050));
    }

    #[test]
    fn non_wav_is_refused() {
        let p = tmp("junk");
        std::fs::write(&p, b"RIFX....WAVE").unwrap();
        assert_eq!(read(&p).unwrap_err().kind(), io::ErrorKind::InvalidData);
    }
}
