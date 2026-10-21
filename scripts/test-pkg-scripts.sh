#!/bin/bash
# Tests the installer's postinstall and the uninstaller against stand-ins for `defaults`, `killall`,
# `open`, `osascript`, `pkill` and the app, so the real 🌐 key setting, login items and apps are never touched.
#   scripts/test-pkg-scripts.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
[ "$(id -u)" != 0 ] || { echo "run as a normal user: as root the scripts switch users and would reach the real defaults" >&2; exit 1; }
mkdir -p "$ROOT/.cache"
T=$(mktemp -d "$ROOT/.cache/pkg-scripts-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/dest/Shepetal.app/Contents/MacOS" "$T/home"
LOG=$T/calls.log

# defaults: one plain file per domain/key under $T/prefs.
cat > "$T/bin/defaults" <<'SH'
#!/bin/bash
case $2 in /*) exec /usr/bin/defaults "$@" ;; esac  # bundle Info.plist reads only
echo "defaults $*" >> "$CALLS"
f="$PREFS/$2.$3"
case $1 in
  read) [ -f "$f" ] && cat "$f" || exit 1 ;;
  write) [ "$4" = -int ] && echo "$5" > "$f" ;;
  delete) rm -f "$f" ;;
esac
SH
for c in killall open osascript logger pgrep pkill; do
  printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n%s\n' "$c" "$([ "$c" = pgrep ] && echo 'exit 1' || echo 'exit 0')" > "$T/bin/$c"
done
printf '#!/bin/bash\necho "app $*" >> "$CALLS"\n' > "$T/dest/Shepetal.app/Contents/MacOS/Shepetal"
plutil -create xml1 "$T/dest/Shepetal.app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string io.backant.shepetal "$T/dest/Shepetal.app/Contents/Info.plist"
chmod +x "$T/bin/"* "$T/dest/Shepetal.app/Contents/MacOS/Shepetal"
export CALLS=$LOG PREFS=$T/prefs PATH="$T/bin:$PATH"
mkdir -p "$PREFS"

fail() { echo "FAIL: $*"; echo "--- calls:"; cat "$LOG"; exit 1; }
post() { : > "$LOG"; bash scripts/pkg/postinstall "$T/pkg" "$T/dest" / / > "$T/out.log" 2>&1; }
pref() { cat "$PREFS/$1" 2>/dev/null || echo unset; }

# 1. Change Input Source (1) -> 0, old value stored, agents restarted, login item, app opened.
echo 1 > "$PREFS/com.apple.HIToolbox.AppleFnUsageType"
post
[ "$(pref com.apple.HIToolbox.AppleFnUsageType)" = 0 ] || fail "the 🌐 key was not set to 0"
[ "$(pref io.backant.shepetal.previousAppleFnUsageType)" = 1 ] || fail "the old value 1 was not stored"
grep -qx "killall TextInputMenuAgent" "$LOG" || fail "TextInputMenuAgent not restarted"
grep -qx "killall -9 TextInputSwitcher" "$LOG" || fail "TextInputSwitcher not killed with -9"
grep -qx "app --postinstall" "$LOG" || fail "Start at login not turned on"
grep -qx "open $T/dest/Shepetal.app" "$LOG" || fail "the app was not opened"
grep -q "🌐 key set to Do Nothing (was 1)" "$T/out.log" || fail "no log line: $(cat "$T/out.log")"
[ "$(grep -c '^defaults write' "$LOG")" = 3 ] || fail "expected exactly three writes (old value, new value, notice flag)"
grep '^defaults write' "$LOG" | grep -v -e 'com.apple.HIToolbox AppleFnUsageType -int 0' -e 'io.backant.shepetal previousAppleFnUsageType' \
  -e 'io.backant.shepetal fnKeyNoticePending -bool true' && fail "wrote some other setting"
grep -qx 'defaults write io.backant.shepetal fnKeyNoticePending -bool true' "$LOG" || fail "the app is not told to announce the change"
echo "ok: postinstall sets the 🌐 key to Do Nothing, keeps the old value, restarts the input agents, turns on login, opens the app"

# 2. Run again after the user changed it to Emoji (2): set to 0 again, the first old value (1) is kept.
echo 2 > "$PREFS/com.apple.HIToolbox.AppleFnUsageType"
post
[ "$(pref com.apple.HIToolbox.AppleFnUsageType)" = 0 ] || fail "not set to 0 on the second install"
[ "$(pref io.backant.shepetal.previousAppleFnUsageType)" = 1 ] || fail "the stored old value was overwritten"
echo "ok: the old value is stored once"

# 3. Already 0: nothing written, nothing restarted.
post
grep -q '^defaults write' "$LOG" && fail "wrote although it was already 0"
grep -q '^killall' "$LOG" && fail "restarted agents although it was already 0"
grep -qx "app --postinstall" "$LOG" || fail "login item step skipped"
echo "ok: already Do Nothing: no write, no restart"

# 4. Absent key: stored as -1; the uninstaller deletes the key again.
rm -f "$PREFS"/*
post
[ "$(pref io.backant.shepetal.previousAppleFnUsageType)" = -1 ] || fail "absent key not stored as -1"
uninstall() { : > "$LOG"; HOME=$T/home SHEPETAL_APPS_DIR=$T/sysapps bash scripts/uninstall-mac.sh "$@" > "$T/out.log" 2>&1; }
mkdir -p "$T/sysapps" "$T/home"
uninstall || fail "uninstall failed: $(cat "$T/out.log")"
[ "$(pref com.apple.HIToolbox.AppleFnUsageType)" = unset ] || fail "uninstall did not delete the key that was absent before"
echo "ok: an absent key is stored as -1 and deleted again on uninstall"

# 5. Uninstall against the stand-ins (SHEPETAL_APPS_DIR keeps it away from the real /Applications).
newapp() { mkdir -p "$1/Contents/MacOS"; cp "$T/dest/Shepetal.app/Contents/MacOS/Shepetal" "$T/dest/Shepetal.app/Contents/Info.plist" "$1/Contents/" 2>/dev/null
           mv "$1/Contents/Shepetal" "$1/Contents/MacOS/Shepetal"; }
mkdir -p "$T/home/Library/Application Support/Shepetal"
newapp "$T/home/Applications/Shepetal.app"
newapp "$T/sysapps/Shepetal.app"
echo 3 > "$PREFS/io.backant.shepetal.previousAppleFnUsageType"
uninstall || fail "uninstall failed: $(cat "$T/out.log")"
[ "$(pref com.apple.HIToolbox.AppleFnUsageType)" = 3 ] || fail "uninstall did not restore 3"
[ "$(pref io.backant.shepetal.previousAppleFnUsageType)" = unset ] || fail "uninstall kept the stored value"
grep -qx "app --unregister-login-item" "$LOG" || fail "uninstall left the login item"
for a in "$T/home/Applications/Shepetal.app" "$T/sysapps/Shepetal.app"; do  # none running: it may still be in its backoff
  grep -qxF "pkill -f ^$a/Contents/MacOS/Shepetal --watchdog" "$LOG" || fail "uninstall did not stop the crash watchdog of $a"
done
grep -qx "killall -9 TextInputSwitcher" "$LOG" || fail "uninstall did not restart TextInputSwitcher"
[ ! -e "$T/home/Applications/Shepetal.app" ] && [ ! -e "$T/sysapps/Shepetal.app" ] || fail "uninstall left an app"
[ -d "$T/home/Library/Application Support/Shepetal" ] || fail "uninstall deleted the recordings"
grep -q "Shepetal is uninstalled." "$T/out.log" || fail "no success line: $(cat "$T/out.log")"
echo "ok: uninstall restores the 🌐 key, removes the login item and the apps, keeps recordings and history"

# 6. An app it cannot remove (root-owned after a .pkg install; here a read-only folder): it asks for
#    admin rights, then says plainly that the app is still there and exits non-zero.
newapp "$T/sysapps/Shepetal.app"
chmod 555 "$T/sysapps"
uninstall && { chmod 755 "$T/sysapps"; fail "uninstall claimed success with the app still there"; }
chmod 755 "$T/sysapps"
grep -q "administrator privileges" "$LOG" || fail "no admin-rights attempt"
grep -q "NOT fully uninstalled" "$T/out.log" || fail "no plain failure message: $(cat "$T/out.log")"
grep -q "Shepetal is uninstalled." "$T/out.log" && fail "printed success although the app is still there"
echo "ok: an app it cannot remove is reported, not hidden"

# 7. Something else at ~/Applications/Shepetal.app (another bundle ID) is left alone.
rm -rf "$T/sysapps/Shepetal.app"
newapp "$T/home/Applications/Shepetal.app"
plutil -replace CFBundleIdentifier -string com.example.other "$T/home/Applications/Shepetal.app/Contents/Info.plist"
uninstall || fail "uninstall failed: $(cat "$T/out.log")"
[ -d "$T/home/Applications/Shepetal.app" ] || fail "removed a bundle that is not Shepetal"
echo "ok: a bundle with another ID is not removed"

# 8. preinstall: a running copy is asked to quit as the user.
cat > "$T/bin/pgrep" <<'SH'
#!/bin/bash
echo "pgrep $*" >> "$CALLS"
[ -e "$PREFS/running" ] && exit 0 || exit 1
SH
cat > "$T/bin/osascript" <<'SH'
#!/bin/bash
echo "osascript $*" >> "$CALLS"
rm -f "$PREFS/running"
SH
chmod +x "$T/bin/pgrep" "$T/bin/osascript"
touch "$PREFS/running"
: > "$LOG"
bash scripts/pkg/preinstall "$T/pkg" "$T/dest" / / > "$T/out.log" 2>&1 || fail "preinstall failed"
grep -q "osascript -e quit app \"Shepetal\"" "$LOG" || fail "preinstall did not ask Shepetal to quit"
WD="pkill -f ^$T/dest/Shepetal.app/Contents/MacOS/Shepetal --watchdog"
[ "$(grep -nxF -m1 "$WD" "$LOG" | cut -d: -f1)" -lt "$(grep -n -m1 '^osascript' "$LOG" | cut -d: -f1)" ] 2>/dev/null \
  || fail "preinstall did not stop the crash watchdog before quitting the app (it would open the app again)"
echo "ok: preinstall stops the crash watchdog, then quits a running Shepetal"

# 9. preinstall with the app not running: its watchdog may be waiting to open it again, so it is stopped too.
: > "$LOG"
bash scripts/pkg/preinstall "$T/pkg" "$T/dest" / / > "$T/out.log" 2>&1 || fail "preinstall failed"
grep -qxF "$WD" "$LOG" || fail "preinstall left the crash watchdog running with the app not running"
grep -q '^osascript' "$LOG" && fail "preinstall quit an app that was not running"
echo "ok: preinstall stops the crash watchdog with the app not running"
echo "test-pkg-scripts: OK"
