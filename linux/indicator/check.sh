#!/bin/sh
# Every automated check of the Linux 🤫 indicator, in Docker on ubuntu:24.04:
#   - cargo test (the daemon's socket and the states it sends) and the indicator's unit tests
#   - a real X11 run under Xvfb and a real wlr-layer-shell run in headless Sway, each with
#     screenshots checked pixel by pixel (test_indicator.py shot/pulse)
#   - eslint (recommended rules) on the GNOME Shell extension
# From the repo root: linux/indicator/check.sh [OUT_DIR]   (screenshots go to OUT_DIR, default a
# new temporary dir)
set -eu

if [ "${1:-}" != --in-docker ]; then
    out=${1:-$(mktemp -d)}
    mkdir -p "$out" && out=$(cd "$out" && pwd)
    docker build -q -t shepetal-linux-indicator-test - >/dev/null <<'EOF'
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    ca-certificates cargo python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-gtklayershell-0.1 \
    fonts-noto-color-emoji fonts-dejavu-core xvfb x11-utils xdotool imagemagick sway grim >/dev/null \
 && rm -rf /var/lib/apt/lists/*
EOF
    docker run --rm -v "$PWD/linux":/src:ro -v "$out":/out -w /src -e CARGO_TARGET_DIR=/tmp/target \
        shepetal-linux-indicator-test sh indicator/check.sh --in-docker
    echo "== GNOME Shell extension"
    docker run --rm -v "$PWD/linux/gnome-extension":/ext:ro node:22.11.0-slim sh -ec '
        mkdir /lint && cd /lint && cp /ext/extension.js /ext/metadata.json .
        npm install --silent --no-audit --no-fund eslint@9.13.0 @eslint/js@9.13.0 >/dev/null
        printf "%s\n" "import js from \"@eslint/js\";" \
            "export default [js.configs.recommended, {languageOptions: {globals: {global: \"readonly\"}}}];" \
            > eslint.config.mjs
        npx eslint --max-warnings 0 extension.js
        node -e "const m = require(\"./metadata.json\");
            for (const k of [\"uuid\", \"name\", \"description\", \"shell-version\"]) if (!m[k]) throw new Error(k);"
        echo "ok extension.js: eslint recommended rules, no warnings; metadata.json: valid"'
    echo "all indicator checks passed; screenshots in $out"
    exit 0
fi

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== cargo test"
cargo test > /tmp/cargo.log 2>&1 || { cat /tmp/cargo.log; fail "cargo test"; }
grep '^test result' /tmp/cargo.log
cargo build --release -q
echo "== indicator unit tests"
python3 -B indicator/test_indicator.py

export PATH="/src/indicator:$PATH" NO_AT_BRIDGE=1
hint="Hold fn to talk · double-tap for hands-free"
check() { python3 -B indicator/test_indicator.py "$@"; }

# A full-screen gray window started after 🤫. 🤫 must stay on top of it. It prints "click"
# for each mouse click it gets.
cover() {
    python3 -B -c '
import gi
gi.require_version("Gdk", "3.0"); gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gtk
d = Gdk.Display.get_default()
wl = d.__gtype__.name == "GdkWaylandDisplay"
w = Gtk.Window(type=Gtk.WindowType.TOPLEVEL if wl else Gtk.WindowType.POPUP)
w.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0.3, 0.3, 0.3, 1))
w.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
w.connect("button-press-event", lambda *_: print("click", flush=True))
g = d.get_monitor(0).get_geometry()
w.move(0, 0); w.set_size_request(g.width, g.height)
if wl: w.fullscreen()
w.show_all(); Gtk.main()' 3>&- > /tmp/clicks 2>> /out/cover-stderr.log &  # 3>&-: not holding the daemon's stdin open
}

# The daemon's socket and 🤫 (`shepetal indicator`, which starts shepetal-indicator from PATH),
# fed from fd 3.
start() {
    rm -f /tmp/in && mkfifo /tmp/in
    /tmp/target/release/shepetal indicator < /tmp/in 2> "/out/$1-stderr.log" &
    daemon=$!
    exec 3> /tmp/in
}

# The same steps on each backend. $1: x11 or sway; $grab takes a screenshot.
steps() {
    echo recording >&3; sleep 1
    $grab "/out/$1-recording.png"; check shot "/out/$1-recording.png" recording
    echo "hint $hint" >&3; sleep 0.5
    $grab "/out/$1-hint.png"; check shot "/out/$1-hint.png" recording "$hint"
    echo handsfree >&3; sleep 2  # the hint is gone after about 2 s
    $grab "/out/$1-handsfree.png"; check shot "/out/$1-handsfree.png" handsfree
    echo processing >&3
    for i in 1 2 3; do sleep 0.3; $grab "/out/$1-processing-$i.png"; done
    check pulse "/out/$1-processing-1.png" "/out/$1-processing-2.png" "/out/$1-processing-3.png"
    echo "error Transcription failed" >&3; sleep 0.5
    $grab "/out/$1-error.png"; check shot "/out/$1-error.png" error "Transcription failed"
    echo idle >&3; sleep 4  # the error's text is gone after about 4 s
    $grab "/out/$1-idle.png"; check shot "/out/$1-idle.png" idle
}

# The daemon closes its socket; 🤫 must not outlive it.
stop() {
    exec 3>&-
    wait "$daemon"
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f 'python3 .*shepetal-indicator' >/dev/null || break; sleep 0.2; done
    ! pgrep -f 'python3 .*shepetal-indicator' >/dev/null || fail "$1: shepetal-indicator outlived the daemon"
    echo "ok $1: shepetal-indicator exited with the daemon"
}

echo "== X11 (Xvfb 1280x720, no window manager, no compositor)"
export XDG_RUNTIME_DIR=/tmp/rt-x11 DISPLAY=:99 XDG_SESSION_TYPE=x11
mkdir -m 700 "$XDG_RUNTIME_DIR"
Xvfb :99 -screen 0 1280x720x24 -br -nolisten tcp 2>/dev/null &
xvfb=$!
until xdpyinfo >/dev/null 2>&1; do sleep 0.1; done
start x11
for _ in $(seq 50); do win=$(xdotool search --name '^shepetal$' 2>/dev/null) && break; sleep 0.1; done
[ -n "${win:-}" ] || fail "x11: no 🤫 window"
info=$(xwininfo -id "$win")
for want in "Absolute upper-left X:  8" "Absolute upper-left Y:  694" "Width: 18" "Height: 18" \
            "Map State: IsViewable" "Override Redirect State: yes"; do
    echo "$info" | grep -qF "$want" || fail "x11: xwininfo lacks '$want': $info"
done
echo "ok x11: override-redirect 18x18 window at 8,694 (8 px in from the bottom-left of 1280x720)"
cover
x11_cover=$!
sleep 1.5  # the cover is mapped above 🤫; the 1 s raise puts 🤫 back on top
xdotool mousemove 17 703 click 1
sleep 0.5
grep -q click /tmp/clicks || fail "x11: a click on 🤫 did not reach the window below it"
echo "ok x11: a click on 🤫 reached the window below it (empty input shape)"
grab="import -window root"
steps x11
stop x11
kill "$x11_cover" "$xvfb"

echo "== Wayland (headless Sway 1280x720, wlr-layer-shell)"
export XDG_RUNTIME_DIR=/tmp/rt-sway WAYLAND_DISPLAY=wayland-1 XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=sway
unset DISPLAY
mkdir -m 700 "$XDG_RUNTIME_DIR"
printf 'output HEADLESS-1 resolution 1280x720\nxwayland disable\n' > /tmp/sway.cfg
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman sway -c /tmp/sway.cfg > /out/sway.log 2>&1 &
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break; sleep 0.1; done
export WAYLAND_DEBUG=1  # shepetal ignores it; shepetal-indicator logs its Wayland requests
start sway
unset WAYLAND_DEBUG
sleep 1
cover
sleep 1
log=/out/sway-stderr.log
for want in ', 3, "shepetal")' 'set_anchor(6)' 'set_margin(0, 0, 8, 8)' 'set_keyboard_interactivity(0)' 'set_exclusive_zone(-1)'; do
    grep 'zwlr_layer' "$log" | grep -qF "$want" || fail "sway: no layer-surface request with '$want' in $log"
done
# The last input region set on the surface must be a region with nothing added: click-through.
awk '/create_region\(new id wl_region@/ { match($0, /wl_region@[0-9]+/); adds[substr($0, RSTART, RLENGTH)] = 0 }
     /wl_region@[0-9]+\.add\(/ { match($0, /wl_region@[0-9]+/); adds[substr($0, RSTART, RLENGTH)]++ }
     /set_input_region\(/ { last = 1; n = match($0, /wl_region@[0-9]+/) ? adds[substr($0, RSTART, RLENGTH)] : -1 }
     END { exit !(last && n == 0) }' "$log" || fail "sway: input region is not empty"
echo "ok sway: overlay layer, anchored bottom|left, margins 8, no keyboard, exclusive zone -1, empty input region"
grab=grim
steps sway
stop sway
