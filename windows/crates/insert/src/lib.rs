//! Puts dictated text into the window that stayed in focus (goal rule 8), or leaves it on the clipboard.
//!
//! The decisions below are pure and tested on any OS. The Win32 side (`foreground`, `insert`) is
//! Windows only.
#![cfg_attr(not(windows), allow(dead_code))]

use std::time::{Duration, Instant};

#[cfg(windows)]
mod win;
#[cfg(windows)]
pub use win::{copy, foreground, insert};

/// The foreground window when a dictation starts: its handle and its process.
/// The process id guards against a closed window whose handle was reused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Focus {
    pub hwnd: isize,
    pub pid: u32,
}

/// Why the text was left on the clipboard instead of pasted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hint {
    /// Another window is in front now, or the window could not be read.
    FocusMoved,
    /// The window runs as administrator; UIPI drops our keystrokes into it.
    Elevated,
    /// Ctrl+V went out but nothing read the clipboard within a second.
    NotLanded,
}

macro_rules! press {
    ($why:literal) => {
        concat!($why, " The text is on the clipboard: press Ctrl+V to paste it.")
    };
}

impl Hint {
    /// The text shown next to the indicator.
    pub fn message(self) -> &'static str {
        match self {
            Hint::FocusMoved => press!("The window changed while you spoke."),
            Hint::Elevated => press!("That window runs as administrator, so shepetal can't paste into it."),
            Hint::NotLanded => press!("Paste did not land."),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// The window read the text. `restored` says whether the old clipboard was put back
    /// (false when another app wrote the clipboard during the wait, or the write failed).
    Pasted { restored: bool },
    /// The text is on the clipboard as plain text, the old clipboard is gone, and the hint says why.
    OnClipboard(Hint),
}

pub(crate) const FAIL_AFTER: Duration = Duration::from_secs(1);
pub(crate) const RESTORE_DELAY: Duration = Duration::from_millis(500);

/// Why the text must go to the clipboard, or None to paste. Focus is never moved back.
/// `start`/`now` are the foreground windows at dictation start and at insert time; unreadable counts
/// as moved. `ours`/`target` are integrity levels (mandatory label RIDs); UIPI silently drops
/// SendInput into a higher one, and an unreadable target is taken as higher.
pub(crate) fn gate(start: Option<Focus>, now: Option<Focus>, ours: Option<u32>, target: Option<u32>) -> Option<Hint> {
    if start.is_none() || start != now {
        return Some(Hint::FocusMoved);
    }
    match (ours, target) {
        (Some(o), Some(t)) if t <= o => None,
        _ => Some(Hint::Elevated),
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Paste {
    Waiting,
    /// The target read the text; put the old clipboard back at `restore_at`.
    Landed { restore_at: Instant },
    Failed,
}

/// Where a paste stands. `rendered` is when the target asked for the delayed text. Unlike the Mac,
/// no read can come before Ctrl+V: WM_RENDERFORMAT only arrives while we pump, which starts after it.
pub(crate) fn paste_state(posted: Instant, rendered: Option<Instant>, now: Instant) -> Paste {
    match rendered {
        Some(r) => Paste::Landed { restore_at: r + RESTORE_DELAY },
        None if now.duration_since(posted) >= FAIL_AFTER => Paste::Failed,
        None => Paste::Waiting,
    }
}

/// How one clipboard format is saved so it can be put back.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Keep {
    /// An HGLOBAL: copy its bytes.
    Bytes,
    /// CF_ENHMETAFILE: a GDI handle, saved through GetEnhMetaFileBits.
    Metafile,
    /// Not memory, or owned by the app that wrote it.
    Skip,
}

pub(crate) fn keep(format: u32) -> Keep {
    match format {
        14 => Keep::Metafile,
        // CF_BITMAP, CF_METAFILEPICT and CF_PALETTE are GDI handles, but Windows also lists the CF_DIB
        // and CF_ENHMETAFILE it synthesizes from them, and those are saved. Same for the CF_DSP* ones.
        // ponytail: private (0x200-0x2FF) and GDI object (0x300-0x3FF) formats are lost; nothing common uses them.
        2 | 3 | 9 | 0x80 | 0x82 | 0x83 | 0x8E | 0x200..=0x3FF => Keep::Skip,
        _ => Keep::Bytes,
    }
}

/// CF_UNICODETEXT bytes: UTF-16LE with CRLF line ends (Win32 edit controls ignore a bare LF), NUL-terminated.
pub(crate) fn clipboard_text(text: &str) -> Vec<u8> {
    let crlf = text.replace("\r\n", "\n").replace('\n', "\r\n");
    crlf.encode_utf16().chain([0]).flat_map(u16::to_le_bytes).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const MEDIUM: u32 = 0x2000;
    const HIGH: u32 = 0x3000;
    const NOTEPAD: Focus = Focus { hwnd: 0x10, pid: 7 };

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn pastes_only_into_the_window_that_stayed_in_front() {
        assert_eq!(gate(Some(NOTEPAD), Some(NOTEPAD), Some(MEDIUM), Some(MEDIUM)), None);
        // Another window of the same app (a second document) is a move too.
        let other_window = Focus { hwnd: 0x20, ..NOTEPAD };
        assert_eq!(gate(Some(NOTEPAD), Some(other_window), Some(MEDIUM), Some(MEDIUM)), Some(Hint::FocusMoved));
        // The window closed and its handle went to another process.
        let reused = Focus { pid: 8, ..NOTEPAD };
        assert_eq!(gate(Some(NOTEPAD), Some(reused), Some(MEDIUM), Some(MEDIUM)), Some(Hint::FocusMoved));
    }

    #[test]
    fn unknown_focus_goes_to_the_clipboard() {
        // No foreground window (secure desktop, a switch in progress) can't prove it is the same window.
        assert_eq!(gate(None, None, Some(MEDIUM), Some(MEDIUM)), Some(Hint::FocusMoved));
        assert_eq!(gate(Some(NOTEPAD), None, Some(MEDIUM), Some(MEDIUM)), Some(Hint::FocusMoved));
        assert_eq!(gate(None, Some(NOTEPAD), Some(MEDIUM), Some(MEDIUM)), Some(Hint::FocusMoved));
    }

    #[test]
    fn elevated_windows_go_to_the_clipboard() {
        assert_eq!(gate(Some(NOTEPAD), Some(NOTEPAD), Some(MEDIUM), Some(HIGH)), Some(Hint::Elevated));
        // An admin window usually won't even let us read its token.
        assert_eq!(gate(Some(NOTEPAD), Some(NOTEPAD), Some(MEDIUM), None), Some(Hint::Elevated));
        assert_eq!(gate(Some(NOTEPAD), Some(NOTEPAD), None, Some(MEDIUM)), Some(Hint::Elevated));
        // Same or lower integrity is reachable: elevated shepetal into an admin window, or into a sandboxed app.
        assert_eq!(gate(Some(NOTEPAD), Some(NOTEPAD), Some(HIGH), Some(HIGH)), None);
        assert_eq!(gate(Some(NOTEPAD), Some(NOTEPAD), Some(MEDIUM), Some(0x1000)), None);
        // A moved focus is the better explanation, even when the new window is elevated.
        assert_eq!(gate(Some(NOTEPAD), Some(Focus { hwnd: 0x20, pid: 9 }), Some(MEDIUM), None), Some(Hint::FocusMoved));
    }

    #[test]
    fn a_read_of_the_text_is_the_paste_and_restore_waits_half_a_second_after_it() {
        let t0 = Instant::now();
        assert_eq!(paste_state(t0, None, t0 + ms(999)), Paste::Waiting);
        assert_eq!(paste_state(t0, None, t0 + ms(1000)), Paste::Failed);
        // Restore is timed from the read, not from Ctrl+V: a slow app may still be reading.
        assert_eq!(paste_state(t0, Some(t0 + ms(300)), t0 + ms(310)), Paste::Landed { restore_at: t0 + ms(800) });
        assert_eq!(paste_state(t0, Some(t0 + ms(900)), t0 + ms(2000)), Paste::Landed { restore_at: t0 + ms(1400) });
    }

    #[test]
    fn saves_memory_formats_and_skips_gdi_handles() {
        for text_like in [1, 13, 15, 16, 0x81, 0xC0FF] {
            assert_eq!(keep(text_like), Keep::Bytes, "format {text_like:#x}");
        }
        assert_eq!(keep(14), Keep::Metafile);
        for handle in [2, 3, 9, 0x80, 0x82, 0x83, 0x8E, 0x200, 0x2FF, 0x300, 0x3FF] {
            assert_eq!(keep(handle), Keep::Skip, "format {handle:#x}");
        }
    }

    #[test]
    fn clipboard_text_is_nul_terminated_utf16_with_crlf() {
        let units = |b: Vec<u8>| -> Vec<u16> { b.chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect() };
        assert_eq!(units(clipboard_text("a\nb")), "a\r\nb\0".encode_utf16().collect::<Vec<_>>());
        assert_eq!(units(clipboard_text("a\r\nb")), "a\r\nb\0".encode_utf16().collect::<Vec<_>>());
        assert_eq!(units(clipboard_text("Grüße 🤫")), "Grüße 🤫\0".encode_utf16().collect::<Vec<_>>());
    }

    #[test]
    fn every_hint_tells_the_user_to_press_ctrl_v() {
        for h in [Hint::FocusMoved, Hint::Elevated, Hint::NotLanded] {
            assert!(h.message().ends_with("press Ctrl+V to paste it."), "{h:?}");
        }
    }
}
