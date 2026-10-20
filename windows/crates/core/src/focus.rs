//! Product rule 8: the text is pasted only into the window that was in the foreground when the dictation
//! started, and focus is never moved back. Otherwise the text is left on the clipboard as plain text, the
//! user's old clipboard is not restored, and the hint next to 🤫 says to press Ctrl+V. A paste that does not
//! land (`text::verdict` says Failed) ends the same way, with `NOT_LANDED`.

pub const PRESS_CTRL_V: &str = "The text is on the clipboard: press Ctrl+V to paste it.";
pub const FOCUS_MOVED: &str = "The window changed while you spoke. The text is on the clipboard: press Ctrl+V to paste it.";
pub const NOT_LANDED: &str = "Paste did not land. The text is on the clipboard: press Ctrl+V to paste it.";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Insert {
    /// Send Ctrl+V to the foreground window.
    Paste,
    /// Leave the text on the clipboard and show `hint`.
    Clipboard { hint: &'static str },
}

/// `start` is the foreground window when the dictation started (GetForegroundWindow at `Action::Start`),
/// `now` the one when the text is ready; None when Windows returned no window, which it does while
/// activation is changing hands. Pastes only when both are known and equal. `W` can be (HWND, process id),
/// so a closed window whose handle Windows hands to a new one does not count as the same.
pub fn decide<W: PartialEq>(start: Option<W>, now: Option<W>) -> Insert {
    match (start, now) {
        (Some(a), Some(b)) if a == b => Insert::Paste,
        (Some(_), Some(_)) => Insert::Clipboard { hint: FOCUS_MOVED },
        _ => Insert::Clipboard { hint: PRESS_CTRL_V },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_window_pastes() {
        assert_eq!(decide(Some(0x1234_u64), Some(0x1234)), Insert::Paste);
        assert_eq!(decide(Some((0x1234_u64, 42_u32)), Some((0x1234, 42))), Insert::Paste);
    }

    // The user moved to another window while speaking: the text must not land there, and focus is not
    // taken back to the first one.
    #[test]
    fn another_window_gets_the_clipboard_and_the_hint() {
        assert_eq!(decide(Some(0x1234_u64), Some(0x5678)), Insert::Clipboard { hint: FOCUS_MOVED });
        assert_eq!(
            decide(Some((0x1234_u64, 42_u32)), Some((0x1234, 43))),
            Insert::Clipboard { hint: FOCUS_MOVED },
            "same handle, another process: Windows reused the handle"
        );
    }

    // Rule 8 pastes only into a window known to have stayed in focus; not knowing is not staying.
    #[test]
    fn an_unknown_window_gets_the_clipboard() {
        assert_eq!(decide(None, Some(0x1234_u64)), Insert::Clipboard { hint: PRESS_CTRL_V });
        assert_eq!(decide(Some(0x1234_u64), None), Insert::Clipboard { hint: PRESS_CTRL_V });
        assert_eq!(decide::<u64>(None, None), Insert::Clipboard { hint: PRESS_CTRL_V });
    }

    #[test]
    fn every_hint_says_ctrl_v_not_the_mac_key() {
        for hint in [PRESS_CTRL_V, FOCUS_MOVED, NOT_LANDED] {
            assert!(hint.ends_with(PRESS_CTRL_V), "{hint}");
            assert!(!hint.contains('⌘'), "{hint}");
        }
    }
}
