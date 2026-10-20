//! Goal rule 8: dictated text goes only into the window that stayed in focus; otherwise it is left
//! on the clipboard and the hint says to paste. shepetal never moves focus back.
//!
//! The daemon reads the focused window when a dictation starts and again when the text is ready.
//! Where the session cannot tell (GNOME and KDE on Wayland), it types and nothing else checks.

use std::process::Command;

/// How this session tells which window has focus.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Session {
    /// `xdotool getactivewindow` (EWMH `_NET_ACTIVE_WINDOW`).
    X11,
    /// `swaymsg -t get_tree`: the node with `"focused": true`.
    Sway,
    /// `hyprctl activewindow -j`: its `address`.
    Hyprland,
    /// No way to read the focused window (GNOME or KDE on Wayland, or no session at all).
    Unknown,
}

impl Session {
    /// From `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, and whether `DISPLAY`, `SWAYSOCK` and
    /// `HYPRLAND_INSTANCE_SIGNATURE` are set. A session started with `startx` reports `tty`, so
    /// any non-Wayland session with a `DISPLAY` counts as X11, as the typing side does.
    pub fn detect(session: &str, desktop: &str, display: bool, swaysock: bool, hyprland: bool) -> Session {
        let desktop = desktop.to_ascii_lowercase();
        match session {
            "wayland" if hyprland || desktop.contains("hyprland") => Session::Hyprland,
            "wayland" if swaysock || desktop.contains("sway") => Session::Sway,
            "wayland" => Session::Unknown,
            "x11" => Session::X11,
            _ if display => Session::X11,
            _ => Session::Unknown,
        }
    }

    pub fn from_env() -> Session {
        let var = |k| std::env::var(k).unwrap_or_default();
        let set = |k| std::env::var_os(k).is_some_and(|v| !v.is_empty());
        Session::detect(&var("XDG_SESSION_TYPE"), &var("XDG_CURRENT_DESKTOP"), set("DISPLAY"), set("SWAYSOCK"), set("HYPRLAND_INSTANCE_SIGNATURE"))
    }

    /// What `daemon` says at start when rule 8 cannot apply here, or None when it can.
    pub fn unreadable_note(self) -> Option<&'static str> {
        (self == Session::Unknown).then_some(
            "this desktop does not tell apps which window has focus, so text is typed into whatever window has focus when it is ready (goal rule 8 needs X11, Sway or Hyprland)")
    }

    /// An id of the focused window, or None when it cannot be read.
    pub fn focused(self) -> Option<String> {
        let run = |bin: &str, args: &[&str]| run_briefly(bin, args, std::time::Duration::from_millis(500));
        match self {
            Session::X11 => run("xdotool", &["getactivewindow"]).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
            Session::Sway => sway_focused(&run("swaymsg", &["-t", "get_tree"])?),
            Session::Hyprland => hyprland_focused(&run("hyprctl", &["activewindow", "-j"])?),
            Session::Unknown => None,
        }
    }
}

/// Run `bin` and return its stdout if it exits 0 within `limit`. A hung tool (a stuck compositor
/// IPC, an X server that does not answer) is killed, so it cannot hold up a dictation.
pub fn run_briefly(bin: &str, args: &[&str], limit: std::time::Duration) -> Option<String> {
    use std::io::Read;
    let mut child = Command::new(bin).args(args).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null()).spawn().ok()?;
    // Read on a thread: a big sway tree fills the pipe before the tool exits.
    let mut out = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut s = String::new();
        out.read_to_string(&mut s).map(|_| s)
    });
    let start = std::time::Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break Some(st),
            Ok(None) if start.elapsed() < limit => std::thread::sleep(std::time::Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let text = reader.join().ok()?.ok()?;
    status.filter(|s| s.success()).map(|_| text)
}

/// The id of the focused node in `swaymsg -t get_tree` output.
pub fn sway_focused(tree: &str) -> Option<String> {
    fn find(n: &serde_json::Value) -> Option<String> {
        if n["focused"] == true {
            return Some(n["id"].to_string());
        }
        ["nodes", "floating_nodes"].iter().filter_map(|k| n[k].as_array()).flatten().find_map(find)
    }
    find(&serde_json::from_str(tree).ok()?)
}

/// The `address` in `hyprctl activewindow -j` output (`{}` when no window has focus).
pub fn hyprland_focused(json: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    v["address"].as_str().filter(|a| !a.is_empty()).map(String::from)
}

/// Where the text goes.
#[derive(Debug, PartialEq)]
pub enum Target {
    /// Type it into the focused window.
    Type,
    /// Leave it on the clipboard: focus moved to another window.
    Clipboard,
}

/// The same window at both ends: type. A different one: clipboard. Unreadable at either end:
/// type, since there is nothing to compare (rule 8 on sessions that cannot tell).
pub fn target(at_start: Option<&str>, now: Option<&str>) -> Target {
    match (at_start, now) {
        (Some(a), Some(b)) if a != b => Target::Clipboard,
        _ => Target::Type,
    }
}

/// Shown next to 🤫 when the text was left on the clipboard. Our own wording.
pub fn clipboard_hint(why: &str) -> String {
    format!("{why} The text is on the clipboard: press Ctrl+V (Ctrl+Shift+V in a terminal).")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_same_window_gets_the_text() {
        assert_eq!(target(Some("41943047"), Some("41943047")), Target::Type);
        assert_eq!(target(Some("41943047"), Some("54525959")), Target::Clipboard);
        // Unreadable focus at either end: nothing to compare, so type.
        assert_eq!(target(None, Some("54525959")), Target::Type);
        assert_eq!(target(Some("41943047"), None), Target::Type);
        assert_eq!(target(None, None), Target::Type);
    }

    #[test]
    fn session_picks_how_focus_is_read() {
        use Session::*;
        assert_eq!(Session::detect("x11", "XFCE", true, false, false), X11);
        assert_eq!(Session::detect("x11", "ubuntu:GNOME", true, false, false), X11);
        assert_eq!(Session::detect("tty", "", true, false, false), X11, "startx reports tty");
        assert_eq!(Session::detect("", "i3", true, false, false), X11);
        assert_eq!(Session::detect("wayland", "sway", true, false, false), Sway, "XWayland's DISPLAY does not make it X11");
        assert_eq!(Session::detect("wayland", "", false, true, false), Sway);
        assert_eq!(Session::detect("wayland", "Hyprland", false, false, false), Hyprland);
        assert_eq!(Session::detect("wayland", "", false, false, true), Hyprland);
        assert_eq!(Session::detect("wayland", "ubuntu:GNOME", true, false, false), Unknown);
        assert_eq!(Session::detect("wayland", "KDE", false, false, false), Unknown);
        assert_eq!(Session::detect("", "", false, false, false), Unknown);
        assert_eq!(Session::detect("tty", "", false, false, false), Unknown);
        assert_eq!(Unknown.focused(), None);
        assert!(Unknown.unreadable_note().is_some() && X11.unreadable_note().is_none() && Sway.unreadable_note().is_none());
    }

    #[test]
    fn sway_tree_gives_the_focused_node() {
        // Trimmed from `swaymsg -t get_tree` (sway 1.9): output > workspace > windows.
        let tree = r#"{"id": 1, "focused": false, "nodes": [
            {"id": 3, "type": "output", "focused": false, "nodes": [
                {"id": 4, "type": "workspace", "focused": false, "nodes": [
                    {"id": 7, "app_id": "foot", "focused": false, "nodes": []}],
                 "floating_nodes": [
                    {"id": 9, "app_id": "firefox", "focused": true, "nodes": []}]}]}]}"#;
        assert_eq!(sway_focused(tree).as_deref(), Some("9"));
        assert_eq!(sway_focused(&tree.replace("true", "false")), None);
        assert_eq!(sway_focused("not json"), None);
    }

    #[test]
    fn hyprland_gives_the_active_window_address() {
        assert_eq!(hyprland_focused(r#"{"address": "0x5581c0a1b2c0", "class": "kitty"}"#).as_deref(), Some("0x5581c0a1b2c0"));
        assert_eq!(hyprland_focused("{}"), None);
        assert_eq!(hyprland_focused(""), None);
    }
}
