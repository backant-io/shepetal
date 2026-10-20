# Linux packages

Run from the repo root. Needs Rust, `cargo install cargo-deb --version 3.8.0 --locked` and curl.

```sh
linux/packaging/test-files.sh       # unit, desktop entry, icon, deb.toml, AppRun checks
linux/packaging/build-deb.sh        # -> linux/target/debian/shepetal_<version>-1_amd64.deb
linux/packaging/build-appimage.sh   # -> linux/target/appimage/shepetal-<version>-x86_64.AppImage
docker run --rm -v "$PWD/linux":/src -w /src ubuntu:24.04 \
  packaging/test-deb.sh target/debian/shepetal_0.0.1-1_amd64.deb
```

`test-deb.sh` installs the `.deb` as root in a fresh container and checks: the postinst message,
`shepetal probe --pw-dump fixtures/pw-dump-meeting.json`, `systemd-analyze verify` of the unit,
that the service is enabled only for the `sudo` user who agreed (never for root, never for another
user who upgrades later), that the link is owned by that user, and that removal undoes it.

| File | Installed as | What it does |
| --- | --- | --- |
| `shepetal.service` | `/usr/lib/systemd/user/` | `shepetal daemon` with the graphical session, `Restart=on-failure`, reads `~/.config/shepetal/env` |
| `shepetal.desktop` | `/usr/share/applications/` | starts the user service through `launch`, so two daemons never run |
| `shepetal.svg` | `/usr/share/icons/hicolor/scalable/apps/` | the 🤫 icon, drawn for shepetal |
| `user-service` | `/usr/lib/shepetal/` | finds the installing user (`SUDO_USER`, `PKEXEC_UID`), links the unit into their `graphical-session.target.wants` as that user, and removes the link on uninstall |
| `debian/` | maintainer scripts | debconf question (default no), input group and `shepetal probe` message |
| `deb.toml` | | cargo-deb settings; `build-deb.sh` appends them to a staged copy of `Cargo.toml` |
| `AppRun` | AppImage entry | no arguments: start the daemon; `install-service` / `uninstall-service`; else passes through |

Preseed the start-at-login answer for an unattended install (both keys; the answer only counts
for the named user):

```sh
printf 'shepetal shepetal/enable-user-service boolean true\nshepetal shepetal/service-user string alice\n' | sudo debconf-set-selections
```

Known gaps: graphical-session.target is reached on GNOME and KDE; on Sway or Hyprland start it
from the compositor config (`exec systemctl --user start graphical-session.target`) or run
`shepetal daemon` there. Lintian still warns `no-manual-page` and `initial-upload-closes-no-bugs`.
