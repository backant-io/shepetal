#!/bin/bash
# Release check of the built app bundle, launched the way Finder launches it (LaunchServices):
#   - it starts with --no-permission-prompts and stays running in the background for SOAK seconds;
#   - it is a menu-bar-only app (LaunchServices type UIElement: no Dock icon, no app switcher entry);
#   - its 🤫 panel is on screen, 18 pt, 8 pt in from the bottom-left corner of the main display;
#   - "Quit Shepetal" from the real status menu ends it (--quit-from-menu-after; nothing is clicked).
# It also tries a screenshot; without Screen Recording permission macOS leaves windows out of it,
# so the window-list check above is the one that counts.
#
# The app shows its 🤫 for the whole run, so the check holds the shared UI lock, uses a scratch
# data dir, never asks for a permission and never takes focus.
#
#   scripts/check-app.sh [path/to/Shepetal.app]     SOAK=300 by default (5 minutes)
set -euo pipefail
cd "$(dirname "$0")/.."
APP=$(cd "$(dirname "${1:-dist/Shepetal.app}")" && pwd)/$(basename "${1:-dist/Shepetal.app}")
SOAK=${SOAK:-300}
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr / -)
TMP=${CHECK_TMP:-$HOME/shepetal-agent/tmp/$BRANCH/check-app}
HOMEDIR=${CHECK_HOME:-$HOME/shepetal-agent/home/$BRANCH}
LOCK=${UI_LOCK:-/Users/sorcecoder/shepetal-re/locks/mac-ui}
mkdir -p "$TMP" "$HOMEDIR"
[ -x "$APP/Contents/MacOS/Shepetal" ] || { echo "no app at $APP" >&2; exit 1; }

# Window-list probe: bounds and level of the app's on-screen windows (no Screen Recording needed).
PROBE=$TMP/windows
if [ ! -x "$PROBE" ] || [ "$0" -nt "$PROBE" ]; then
  cat > "$TMP/windows.swift" <<'SWIFT'
import AppKit
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let main = CGDisplayBounds(CGMainDisplayID())
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    let b = w[kCGWindowBounds as String] as! [String: Double]
    print("window x=\(Int(b["X"]!)) y=\(Int(b["Y"]!)) w=\(Int(b["Width"]!)) h=\(Int(b["Height"]!)) layer=\(w[kCGWindowLayer as String]!)")
}
print("display w=\(Int(main.width)) h=\(Int(main.height))")
SWIFT
  swiftc -O "$TMP/windows.swift" -o "$PROBE"
fi

until mkdir "$LOCK" 2>/dev/null; do sleep 15; done
PID=
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT

if pgrep -qf "$APP/Contents/MacOS/Shepetal"; then echo "this app is already running; quit it first" >&2; exit 1; fi
rm -f "$TMP/stderr.log"
touch "$TMP/started"
START=$(date +%s)
open -g -n --env SHEPETAL_HOME="$HOMEDIR" --stderr "$TMP/stderr.log" --stdout "$TMP/stdout.log" \
  "$APP" --args --no-permission-prompts --quit-from-menu-after "$SOAK"
for _ in $(seq 1 40); do PID=$(pgrep -nf "$APP/Contents/MacOS/Shepetal" || true); [ -n "$PID" ] && break; sleep 0.25; done
[ -n "$PID" ] || { echo "FAIL: the app did not start" >&2; cat "$TMP/stderr.log" >&2; exit 1; }
echo "started pid $PID"
sleep 5

fail() { echo "FAIL: $*" >&2; exit 1; }
TYPE=$(lsappinfo info -only ApplicationType -app "$(lsappinfo find pid="$PID")" | sed 's/.*="\(.*\)"/\1/')
[ "$TYPE" = UIElement ] || fail "LaunchServices type is '$TYPE', expected UIElement (no Dock icon)"
echo "ok: menu-bar only (LaunchServices type $TYPE)"

"$PROBE" "$PID" > "$TMP/windows.txt"
cat "$TMP/windows.txt"
DH=$(sed -n 's/^display w=[0-9]* h=\([0-9]*\)$/\1/p' "$TMP/windows.txt")
grep -qx "window x=8 y=$((DH - 8 - 18)) w=18 h=18 layer=25" "$TMP/windows.txt" \
  || fail "no 18x18 🤫 panel 8 pt from the bottom-left corner (display height $DH)"
echo "ok: 🤫 panel on screen at the bottom-left corner"

screencapture -x "$TMP/screen.png" && echo "screenshot: $TMP/screen.png (empty of windows without Screen Recording permission)"

# Still alive just before the menu quits it, then gone shortly after.
WAIT=$((START + SOAK - 4 - $(date +%s)))
[ "$WAIT" -gt 0 ] && sleep "$WAIT"
UP=$(( $(date +%s) - START ))
kill -0 "$PID" 2>/dev/null || fail "the app exited after ${UP}s, before the menu quit at ${SOAK}s: $(cat "$TMP/stderr.log")"
"$PROBE" "$PID" | grep -q "^window x=8 y=$((DH - 26)) w=18 h=18" || fail "the 🤫 panel is gone after ${UP}s"
echo "ok: still running in the background with 🤫 shown after ${UP}s (rss $(ps -o rss= -p "$PID" | tr -d ' ') KB)"
for _ in $(seq 1 120); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
kill -0 "$PID" 2>/dev/null && fail "Quit Shepetal from the menu did not end the app"
grep -q "no Quit Shepetal item" "$TMP/stderr.log" && fail "the menu has no Quit Shepetal item"
PID=
CRASH=$(find "$HOME/Library/Logs/DiagnosticReports" -name 'Shepetal*' -newer "$TMP/started" 2>/dev/null | head -1)
[ -z "$CRASH" ] || fail "it crashed: $CRASH"
echo "ok: Quit Shepetal from the status menu ended the app (no crash report)"
echo "check-app: OK"
