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
    /// From `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, and whether `SWAYSOCK` and
    /// `HYPRLAND_INSTANCE_SIGNATURE` are set.
    pub fn detect(session: &str, desktop: &str, swaysock: bool, hyprland: bool) -> Session {
        let desktop = desktop.to_ascii_lowercase();
        match session {
            "x11" => Session::X11,
            "wayland" if hyprland || desktop.contains("hyprland") => Session::Hyprland,
            "wayland" if swaysock || desktop.contains("sway") => Session::Sway,
            _ => Session::Unknown,
        }
    }

    pub fn from_env() -> Session {
        let var = |k| std::env::var(k).unwrap_or_default();
        let set = |k| std::env::var_os(k).is_some_and(|v| !v.is_empty());
        Session::detect(&var("XDG_SESSION_TYPE"), &var("XDG_CURRENT_DESKTOP"), set("SWAYSOCK"), set("HYPRLAND_INSTANCE_SIGNATURE"))
    }

    /// An id of the focused window, or None when it cannot be read.
    pub fn focused(self) -> Option<String> {
        let run = |bin: &str, args: &[&str]| {
            let out = Command::new(bin).args(args).output().ok().filter(|o| o.status.success())?;
            Some(String::from_utf8_lossy(&out.stdout).into_owned())
        };
        match self {
            Session::X11 => run("xdotool", &["getactivewindow"]).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
            Session::Sway => sway_focused(&run("swaymsg", &["-t", "get_tree"])?),
            Session::Hyprland => hyprland_focused(&run("hyprctl", &["activewindow", "-j"])?),
            Session::Unknown => None,
        }
    }
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
        assert_eq!(Session::detect("x11", "XFCE", false, false), X11);
        assert_eq!(Session::detect("x11", "ubuntu:GNOME", false, false), X11);
        assert_eq!(Session::detect("wayland", "sway", false, false), Sway);
        assert_eq!(Session::detect("wayland", "", true, false), Sway);
        assert_eq!(Session::detect("wayland", "Hyprland", false, false), Hyprland);
        assert_eq!(Session::detect("wayland", "", false, true), Hyprland);
        assert_eq!(Session::detect("wayland", "ubuntu:GNOME", false, false), Unknown);
        assert_eq!(Session::detect("wayland", "KDE", false, false), Unknown);
        assert_eq!(Session::detect("", "", false, false), Unknown);
        assert_eq!(Unknown.focused(), None);
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
