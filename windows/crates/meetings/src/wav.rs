//! 16 kHz mono 16-bit PCM WAV writer whose header is rewritten after every batch, so a crash or
//! power cut mid-meeting still leaves a playable file with everything up to the last batch.
#![cfg_attr(not(windows), allow(dead_code))]

use std::fs::File;
use std::io::{self, Seek, SeekFrom, Write};
use std::path::Path;

pub const RATE: u32 = 16_000;

pub struct Wav {
    file: File,
    bytes: u32,
}

impl Wav {
    /// Fails if `path` exists: meeting audio is always kept, never overwritten.
    pub fn create(path: &Path) -> io::Result<Wav> {
        let mut file = File::create_new(path)?;
        file.write_all(&header(0))?;
        Ok(Wav { file, bytes: 0 })
    }

    pub fn frames(&self) -> u64 {
        self.bytes as u64 / 2
    }

    /// Little-endian i16 samples.
    pub fn write(&mut self, pcm: &[u8]) -> io::Result<()> {
        self.file.write_all(pcm)?;
        // ponytail: u32 sizes cap a WAV at 4 GB = 37 h at 32 kB/s; saturate rather than wrap.
        self.bytes = self.bytes.saturating_add(pcm.len() as u32);
        Ok(())
    }

    pub fn silence(&mut self, frames: u64) -> io::Result<()> {
        self.write(&vec![0; frames as usize * 2])
    }

    /// Puts the current sizes in the header.
    pub fn sync(&mut self) -> io::Result<()> {
        self.file.seek(SeekFrom::Start(0))?;
        self.file.write_all(&header(self.bytes))?;
        self.file.seek(SeekFrom::End(0))?;
        Ok(())
    }
}

fn header(data: u32) -> Vec<u8> {
    let mut h = Vec::with_capacity(44);
    h.extend_from_slice(b"RIFF");
    h.extend_from_slice(&data.saturating_add(36).to_le_bytes());
    h.extend_from_slice(b"WAVEfmt ");
    h.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
    h.extend_from_slice(&1u16.to_le_bytes()); // PCM
    h.extend_from_slice(&1u16.to_le_bytes()); // mono
    h.extend_from_slice(&RATE.to_le_bytes());
    h.extend_from_slice(&(RATE * 2).to_le_bytes()); // bytes per second
    h.extend_from_slice(&2u16.to_le_bytes()); // block align
    h.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    h.extend_from_slice(b"data");
    h.extend_from_slice(&data.to_le_bytes());
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u32_at(b: &[u8], i: usize) -> u32 {
        u32::from_le_bytes(b[i..i + 4].try_into().unwrap())
    }

    #[test]
    fn header_is_valid_after_every_sync_and_never_overwrites() {
        let path =
            std::env::temp_dir().join(format!("shepetal-wav-test-{}.wav", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let mut w = Wav::create(&path).unwrap();
        w.write(&[1, 0, 2, 0]).unwrap();
        w.silence(3).unwrap();
        w.sync().unwrap();
        // The file as a crash would leave it: no close, no drop yet.
        let b = std::fs::read(&path).unwrap();
        assert_eq!(&b[0..4], b"RIFF");
        assert_eq!(u32_at(&b, 4), 36 + 10, "RIFF size");
        assert_eq!(&b[8..16], b"WAVEfmt ");
        assert_eq!(u32_at(&b, 24), 16_000, "sample rate");
        assert_eq!(u32_at(&b, 28), 32_000, "byte rate");
        assert_eq!(&b[36..40], b"data");
        assert_eq!(u32_at(&b, 40), 10, "data size");
        assert_eq!(&b[44..], &[1, 0, 2, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(w.frames(), 5);

        // Appending after a sync keeps the earlier samples in place.
        w.write(&[9, 0]).unwrap();
        w.sync().unwrap();
        let b = std::fs::read(&path).unwrap();
        assert_eq!(u32_at(&b, 40), 12);
        assert_eq!(&b[44..], &[1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 9, 0]);

        assert!(
            Wav::create(&path).is_err(),
            "an existing recording must not be replaced"
        );
        assert_eq!(std::fs::read(&path).unwrap().len(), 56);
        std::fs::remove_file(&path).unwrap();
    }
}
