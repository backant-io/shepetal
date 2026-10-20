//! Choose how to put text at the cursor, and do it.

use std::process::Command;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Backend {
    Wtype,
    Xdotool,
    Ydotool,
    /// No key injector: copy the text and let the user paste it.
    WlCopy,
    Xclip,
}

pub struct Env<'a> {
    /// XDG_SESSION_TYPE: "wayland", "x11" or empty.
    pub session: &'a str,
    /// XDG_CURRENT_DESKTOP, e.g. "ubuntu:GNOME".
    pub desktop: &'a str,
}

pub fn choose(env: &Env, has: impl Fn(&str) -> bool) -> Option<Backend> {
    let wayland = env.session == "wayland";
    // GNOME's Mutter has no virtual-keyboard protocol, so wtype fails there.
    let gnome = env.desktop.to_ascii_uppercase().contains("GNOME");
    let order: &[Backend] = if wayland {
        &[Backend::Wtype, Backend::Ydotool, Backend::WlCopy]
    } else {
        &[Backend::Xdotool, Backend::Ydotool, Backend::Xclip]
    };
    order.iter().copied().find(|b| !(gnome && *b == Backend::Wtype) && has(b.bin()))
}

impl Backend {
    pub fn bin(self) -> &'static str {
        match self {
            Backend::Wtype => "wtype",
            Backend::Xdotool => "xdotool",
            Backend::Ydotool => "ydotool",
            Backend::WlCopy => "wl-copy",
            Backend::Xclip => "xclip",
        }
    }

    pub fn insert(self, text: &str) -> std::io::Result<()> {
        // ponytail: the clipboard fallbacks do not restore the old clipboard, since nothing
        // sends the paste and restoring would erase the text before the user pastes it.
        let args: Vec<&str> = match self {
            Backend::Wtype => vec!["--", text],
            Backend::Xdotool => vec!["type", "--clearmodifiers", "--", text],
            Backend::Ydotool => vec!["type", "--", text],
            Backend::WlCopy => vec!["--", text],
            Backend::Xclip => return pipe("xclip", &["-selection", "clipboard"], text),
        };
        let st = Command::new(self.bin()).args(args).status()?;
        if st.success() { Ok(()) } else { Err(std::io::Error::other(format!("{} failed: {st}", self.bin()))) }
    }
}

fn pipe(bin: &str, args: &[&str], text: &str) -> std::io::Result<()> {
    use std::io::Write;
    let mut child = Command::new(bin).args(args).stdin(std::process::Stdio::piped()).spawn()?;
    child.stdin.take().unwrap().write_all(text.as_bytes())?;
    child.wait()?;
    Ok(())
}

/// Is `bin` an executable on PATH?
pub fn on_path(bin: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(bin).is_file()))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use Backend::*;

    fn pick(session: &str, desktop: &str, bins: &[&str]) -> Option<Backend> {
        choose(&Env { session, desktop }, |b| bins.contains(&b))
    }

    const ALL: &[&str] = &["wtype", "xdotool", "ydotool", "wl-copy", "xclip"];

    #[test]
    fn session_type_picks_native_typer() {
        assert_eq!(pick("wayland", "sway", ALL), Some(Wtype));
        assert_eq!(pick("x11", "XFCE", ALL), Some(Xdotool));
        // xdotool on Wayland only reaches XWayland windows, so never pick it there.
        assert_eq!(pick("wayland", "KDE", &["xdotool", "ydotool"]), Some(Ydotool));
    }

    #[test]
    fn gnome_wayland_skips_wtype() {
        assert_eq!(pick("wayland", "ubuntu:GNOME", ALL), Some(Ydotool));
    }

    #[test]
    fn ydotool_then_clipboard_are_fallbacks() {
        assert_eq!(pick("x11", "", &["ydotool", "xclip"]), Some(Ydotool));
        assert_eq!(pick("wayland", "", &["wl-copy", "xclip"]), Some(WlCopy));
        assert_eq!(pick("x11", "", &["wl-copy", "xclip"]), Some(Xclip));
        assert_eq!(pick("wayland", "", &[]), None);
    }
}
