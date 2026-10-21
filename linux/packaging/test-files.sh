#!/bin/sh
# Checks the packaging files without installing anything. Needs python3; uses
# desktop-file-validate and systemd-analyze when they are installed.
set -eu
pkg=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qxF "$2" "$pkg/$1" || fail "$1 lacks the line: $2"; }

for f in AppRun launch user-service build-deb.sh build-appimage.sh test-deb.sh test-files.sh \
         debian/config debian/postinst debian/prerm debian/postrm; do
    sh -n "$pkg/$f" || fail "$f: syntax"
    [ -x "$pkg/$f" ] || fail "$f is not executable"
done

# Unit: starts with the graphical login, restarts on failure, but not forever.
has shepetal.service 'ExecStart=/usr/bin/shepetal daemon'
has shepetal.service 'Restart=on-failure'
has shepetal.service 'WantedBy=graphical-session.target'
has shepetal.service 'PartOf=graphical-session.target'
has shepetal.service 'StartLimitBurst=5'
if command -v systemd-analyze >/dev/null; then
    # The binary is not installed here, so verify a copy that runs /bin/true.
    mkdir -p "$tmp/run" "$tmp/unit"
    sed 's|^ExecStart=/usr/bin/shepetal|ExecStart=/bin/true|' "$pkg/shepetal.service" > "$tmp/unit/shepetal.service"
    XDG_RUNTIME_DIR="$tmp/run" systemd-analyze verify --user "$tmp/unit/shepetal.service" 2>"$tmp/verify" ||
        { cat "$tmp/verify"; fail "systemd-analyze rejects shepetal.service"; }
    ! grep -v 'Failed to connect to system bus' "$tmp/verify" | grep . ||
        fail "systemd-analyze warns about shepetal.service"
fi
# user-service links into the target the unit is wanted by.
grep -q 'graphical-session.target.wants' "$pkg/user-service" || fail "user-service links into another target"

# Desktop entry and icon.
has shepetal.desktop 'Icon=shepetal'
has shepetal.desktop 'Exec=/usr/lib/shepetal/launch'
has launch 'exec systemctl --user start shepetal.service'
if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$pkg/shepetal.desktop" || fail "desktop-file-validate"
fi
python3 - "$pkg/shepetal.svg" <<'PY' || fail "shepetal.svg"
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.tag == "{http://www.w3.org/2000/svg}svg", root.tag
assert root.get("viewBox") == "0 0 128 128", "square viewBox"
PY

# deb.toml: every asset exists, and the unit, entry and icon land where systemd and desktops look.
python3 - "$pkg" <<'PY' || fail "deb.toml"
import os, sys, tomllib
pkg = sys.argv[1]
deb = tomllib.load(open(os.path.join(pkg, "deb.toml"), "rb"))["package"]["metadata"]["deb"]
assets = {src: dst for src, dst, _ in deb["assets"]}
for src in assets:
    if not src.startswith("target/"):
        assert os.path.exists(os.path.join(pkg, "..", src)), src
assert assets["packaging/shepetal.service"] == "usr/lib/systemd/user/", assets
assert assets["packaging/shepetal.desktop"] == "usr/share/applications/", assets
assert assets["packaging/shepetal.svg"] == "usr/share/icons/hicolor/scalable/apps/", assets
assert assets["packaging/user-service"] == "usr/lib/shepetal/", assets
assert assets["packaging/launch"] == "usr/lib/shepetal/", assets
assert "debconf" in deb["depends"], "postinst needs debconf"
PY

# The changelog names the version cargo-deb builds (Cargo.toml version, revision 1).
version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$pkg/../Cargo.toml" | head -1)
head -1 "$pkg/changelog" | grep -qF "shepetal ($version-1)" || fail "changelog does not start with $version-1"

# installing-user: the sudo/pkexec user, never root.
me=$(id -un)
[ "$(SUDO_USER= PKEXEC_UID= "$pkg/user-service" installing-user)" = "" ] || fail "installing-user without sudo"
[ "$(SUDO_USER=root "$pkg/user-service" installing-user)" = "" ] || fail "installing-user picked root"
if [ "$(id -u)" != 0 ]; then
    [ "$(SUDO_USER="$me" "$pkg/user-service" installing-user)" = "$me" ] || fail "installing-user from SUDO_USER"
    [ "$(SUDO_USER= PKEXEC_UID="$(id -u)" "$pkg/user-service" installing-user)" = "$me" ] || fail "installing-user from PKEXEC_UID"
else
    [ "$(SUDO_USER=nobody "$pkg/user-service" installing-user)" = nobody ] || fail "installing-user from SUDO_USER"
    [ "$(SUDO_USER= PKEXEC_UID=65534 "$pkg/user-service" installing-user)" = nobody ] || fail "installing-user from PKEXEC_UID"
fi

# AppRun install-service: the unit runs this AppImage, quoted, wherever it lives.
mkdir -p "$tmp/app/usr/share/shepetal" "$tmp/app/usr/bin" "$tmp/bin" "$tmp/home"
cp "$pkg/AppRun" "$tmp/app/AppRun"
cp "$pkg/shepetal.service" "$tmp/app/usr/share/shepetal/"
printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\n' "$tmp" > "$tmp/bin/systemctl"
printf '#!/bin/sh\necho "shepetal $*"\n' > "$tmp/app/usr/bin/shepetal"
chmod 755 "$tmp/bin/systemctl" "$tmp/app/usr/bin/shepetal"
run() { HOME="$tmp/home" XDG_CONFIG_HOME= PATH="$tmp/bin:$PATH" APPIMAGE="$tmp/My Apps/shepetal 100%.AppImage" "$tmp/app/AppRun" "$@"; }
run install-service >/dev/null
unit="$tmp/home/.config/systemd/user/shepetal.service"
grep -qxF "ExecStart=\"$tmp/My Apps/shepetal 100%%.AppImage\" daemon" "$unit" || { cat "$unit"; fail "AppRun unit ExecStart"; }
grep -qxF 'Restart=on-failure' "$unit" || fail "AppRun unit lost Restart="
grep -qxF -- '--user enable shepetal.service' "$tmp/systemctl.log" || fail "AppRun did not enable the unit"
[ "$(run)" = "" ] && grep -qxF -- '--user start shepetal.service' "$tmp/systemctl.log" || fail "AppRun did not start the installed unit"
[ "$(run probe --pw-dump x)" = "shepetal probe --pw-dump x" ] || fail "AppRun does not pass arguments"
run uninstall-service >/dev/null
[ ! -e "$unit" ] || fail "uninstall-service left the unit"
[ "$(run)" = "shepetal daemon" ] || fail "AppRun without a unit does not run the daemon"

echo "packaging files: PASS"
