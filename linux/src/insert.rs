//! Choose how to put text at the cursor, and do it.

use std::process::{Command, Stdio};

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

/// The clipboard tool for this session, for text that is not typed (goal rule 8).
pub fn clipboard(env: &Env, has: impl Fn(&str) -> bool) -> Option<Backend> {
    let order: &[Backend] = if env.session == "wayland" { &[Backend::WlCopy, Backend::Xclip] } else { &[Backend::Xclip] };
    order.iter().copied().find(|b| has(b.bin()))
}

impl Backend {
    /// Copies instead of typing: the user pastes.
    pub fn is_clipboard(self) -> bool {
        matches!(self, Backend::WlCopy | Backend::Xclip)
    }

    pub fn bin(self) -> &'static str {
        match self {
            Backend::Wtype => "wtype",
            Backend::Xdotool => "xdotool",
            Backend::Ydotool => "ydotool",
            Backend::WlCopy => "wl-copy",
            Backend::Xclip => "xclip",
        }
    }

    /// Arguments only: the text always goes over stdin, never argv, because any local user
    /// can read argv with `ps`. The `'static` type keeps dictated text out of here.
    pub fn argv(self) -> &'static [&'static str] {
        match self {
            Backend::Wtype => &["-"],
            Backend::Xdotool => &["type", "--clearmodifiers", "--file", "-"],
            Backend::Ydotool => &["type", "--file", "-"],
            Backend::WlCopy => &[],
            Backend::Xclip => &["-selection", "clipboard"],
        }
    }

    pub fn insert(self, text: &str) -> std::io::Result<()> {
        // ponytail: the clipboard fallbacks do not restore the old clipboard, since nothing
        // sends the paste and restoring would erase the text before the user pastes it.
        use std::io::Write;
        let mut child = Command::new(self.bin()).args(self.argv()).stdin(Stdio::piped()).spawn()?;
        child.stdin.take().unwrap().write_all(text.as_bytes())?; // dropped here: EOF
        let st = child.wait()?;
        if st.success() { Ok(()) } else { Err(std::io::Error::other(format!("{} failed: {st}", self.bin()))) }
    }
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
    fn text_goes_over_stdin_not_argv() {
        // argv is visible to every user via ps, so insert() must pass only the fixed flags there
        // and the text on stdin. Each fake tool exits 1 unless both hold, which fails insert().
        use std::os::unix::fs::PermissionsExt;
        let tools = [
            (Wtype, "-"),
            (Xdotool, "type --clearmodifiers --file -"),
            (Ydotool, "type --file -"),
            (WlCopy, ""),
            (Xclip, "-selection clipboard"),
        ];
        let dir = std::env::temp_dir().join(format!("shepetal-bin-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for (b, args) in tools {
            let f = dir.join(b.bin());
            std::fs::write(&f, format!("#!/bin/sh\n[ \"$*\" = \"{args}\" ] && [ \"$(cat; echo .)\" = \"secret words.\" ]\n")).unwrap();
            std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let path = std::env::var("PATH").unwrap_or_default();
        std::env::set_var("PATH", format!("{}:{path}", dir.display()));
        let got: Vec<_> = tools.iter().map(|(b, _)| (*b, b.insert("secret words").is_ok())).collect();
        std::env::set_var("PATH", path);
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(got, tools.map(|(b, _)| (b, true)));
    }

    #[test]
    fn clipboard_tool_follows_the_session() {
        let clip = |session, bins: &[&str]| clipboard(&Env { session, desktop: "" }, |b| bins.contains(&b));
        assert_eq!(clip("wayland", ALL), Some(WlCopy));
        // XWayland apps read the X clipboard, which Wayland compositors sync.
        assert_eq!(clip("wayland", &["xclip"]), Some(Xclip));
        assert_eq!(clip("x11", ALL), Some(Xclip));
        assert_eq!(clip("x11", &["wl-copy"]), None);
        assert!(WlCopy.is_clipboard() && Xclip.is_clipboard());
        assert!(!Wtype.is_clipboard() && !Xdotool.is_clipboard() && !Ydotool.is_clipboard());
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
