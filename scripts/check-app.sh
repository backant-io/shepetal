#!/bin/bash
# Release check of a built app bundle, run as the bundle's app (LaunchServices sees its Info.plist):
#   - it starts with --no-permission-prompts and stays running in the background for SOAK seconds;
#   - it is a menu-bar-only app (LaunchServices type UIElement: no Dock icon, no app switcher entry);
#   - its 🤫 panel is on screen, 18 pt tall, 8 pt in from the bottom-left corner of the main display;
#   - its menu-bar 🤫 is shown, and "Quit Shepetal" from that real status menu ends it, with no crash
#     report (--quit-from-menu-after; nothing is clicked).
# It also tries a screenshot; without Screen Recording permission macOS leaves windows out of it,
# so the window-list check above is the one that counts.
#
# The check runs a copy of the bundle re-signed ad-hoc. macOS ties permissions to the signature, so the
# copy has none of the grants the installed app may have: it cannot hear fn, record, or paste, and it
# never touches the clipboard, even if someone presses fn during the soak. The binary is the same.
# It shows its 🤫 for the whole run, so it holds the UI lock, uses a scratch data dir, never asks for a
# permission and never takes focus.
#
#   scripts/check-app.sh [path/to/Shepetal.app]
#   SOAK=300 (seconds, default)  CHECK_DIR=<scratch dir, default .cache/check-app>
#   CHECK_HOME=<SHEPETAL_HOME for the run, default $CHECK_DIR/home>
#   UI_LOCK=<lock dir, default the shared one on the build Mac if present, else $TMPDIR/shepetal-mac-ui>
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=${1:-dist/Shepetal.app}
[ -x "$SRC/Contents/MacOS/Shepetal" ] || { echo "no app at $SRC" >&2; exit 1; }
SOAK=${SOAK:-300}
DIR=${CHECK_DIR:-$PWD/.cache/check-app}
HOMEDIR=${CHECK_HOME:-$DIR/home}
if [ -z "${UI_LOCK:-}" ]; then
  if [ -d /Users/sorcecoder/shepetal-re/locks ]; then UI_LOCK=/Users/sorcecoder/shepetal-re/locks/mac-ui
  else UI_LOCK=${TMPDIR:-/tmp}/shepetal-mac-ui; fi
fi
mkdir -p "$DIR" "$HOMEDIR" "$(dirname "$UI_LOCK")"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The copy under test: same binary and resources, ad-hoc signature (no permissions).
APP=$DIR/Shepetal.app
rm -rf "$APP"
ditto "$SRC" "$APP"
codesign --force --deep --sign - "$APP" 2>/dev/null
EXE=$APP/Contents/MacOS/Shepetal
cmp -s "$SRC/Contents/Info.plist" "$APP/Contents/Info.plist" || fail "the copy's Info.plist differs"

# Window-list probe: bounds and level of the app's on-screen windows (no Screen Recording needed).
PROBE=$DIR/windows
if [ ! -x "$PROBE" ] || [ "$0" -nt "$PROBE" ]; then
  cat > "$DIR/windows.swift" <<'SWIFT'
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
  swiftc -O "$DIR/windows.swift" -o "$PROBE"
fi

if pgrep -qf "$EXE"; then fail "a copy from $APP is already running"; fi
until mkdir "$UI_LOCK" 2>/dev/null; do echo "waiting for the UI lock $UI_LOCK" >&2; sleep 15; done
PID=
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  rmdir "$UI_LOCK" 2>/dev/null || true
  rm -rf "$APP"  # so LaunchServices does not keep a second Shepetal.app around
}
trap cleanup EXIT

rm -f "$DIR/stderr.log" "$DIR/stdout.log"
touch "$DIR/started"
START=$(date +%s)
# Started directly (not through `open`) so the check gets the exit status; AppKit still checks the
# process in with LaunchServices as the bundle's app, with its Info.plist (LSUIElement).
SHEPETAL_HOME="$HOMEDIR" "$EXE" --no-permission-prompts --quit-from-menu-after "$SOAK" \
  > "$DIR/stdout.log" 2> "$DIR/stderr.log" &
PID=$!
echo "started pid $PID ($APP, ad-hoc copy of $SRC)"
sleep 3

TYPE=$(lsappinfo info -only ApplicationType -app "$(lsappinfo find pid="$PID")" | sed 's/.*="\(.*\)"/\1/')
[ "$TYPE" = UIElement ] || fail "LaunchServices type is '$TYPE', expected UIElement (no Dock icon)"
echo "ok: menu-bar only (LaunchServices type $TYPE)"

# The panel is 18x18; a hint or error message next to 🤫 widens it for a few seconds, never taller.
panel_ok() {
  "$PROBE" "$PID" > "$DIR/windows.txt"
  DH=$(sed -n 's/^display w=[0-9]* h=\([0-9]*\)$/\1/p' "$DIR/windows.txt")
  grep -Eq "^window x=8 y=$((DH - 8 - 18)) w=(1[89]|[2-9][0-9]|[0-9]{3,}) h=18 layer=25$" "$DIR/windows.txt"
}
panel_ok || fail "no 18 pt 🤫 panel 8 pt from the bottom-left corner: $(tr '\n' ' ' < "$DIR/windows.txt")"
cat "$DIR/windows.txt"
echo "ok: 🤫 panel on screen at the bottom-left corner"

screencapture -x "$DIR/screen.png" && echo "screenshot: $DIR/screen.png (empty of windows without Screen Recording permission)"

# Still alive with the panel just before the menu quits it, then gone shortly after.
WAIT=$((START + SOAK - 4 - $(date +%s)))
[ "$WAIT" -gt 0 ] && sleep "$WAIT"
UP=$(( $(date +%s) - START ))
if ! kill -0 "$PID" 2>/dev/null; then
  wait "$PID" && CODE=0 || CODE=$?
  fail "the app exited with status $CODE after ${UP}s, before the menu quit at ${SOAK}s (143 = killed by SIGTERM from outside): $(cat "$DIR/stderr.log")"
fi
panel_ok || fail "the 🤫 panel is gone after ${UP}s: $(tr '\n' ' ' < "$DIR/windows.txt")"
echo "ok: still running in the background with 🤫 shown after ${UP}s (rss $(ps -o rss= -p "$PID" | tr -d ' ') KB)"
for _ in $(seq 1 120); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
kill -0 "$PID" 2>/dev/null && fail "Quit Shepetal from the menu did not end the app"
wait "$PID" && CODE=0 || CODE=$?
PID=
[ "$CODE" = 0 ] || fail "the app ended with status $CODE, not 0: $(tail -3 "$DIR/stderr.log")"
grep -q "quit-from-menu: menu-bar 🤫 shown" "$DIR/stderr.log" || fail "$(grep quit-from-menu "$DIR/stderr.log" || echo "the menu quit never ran")"
CRASH=$(find "$HOME/Library/Logs/DiagnosticReports" -name 'Shepetal*' -newer "$DIR/started" 2>/dev/null | head -1)
[ -z "$CRASH" ] || fail "it crashed: $CRASH"
echo "ok: $(grep -m1 'quit-from-menu:' "$DIR/stderr.log" | sed 's/^quit-from-menu: //'); the app ended, no crash report"
echo "check-app: OK"
