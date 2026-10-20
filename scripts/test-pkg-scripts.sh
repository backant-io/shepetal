#!/bin/bash
# Tests the installer's postinstall and the uninstaller against stand-ins for `defaults`, `killall`,
# `open`, `osascript` and the app, so the real 🌐 key setting, login items and apps are never touched.
#   scripts/test-pkg-scripts.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
T=$(mktemp -d "$ROOT/.cache/pkg-scripts-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/dest/Shepetal.app/Contents/MacOS" "$T/home"
LOG=$T/calls.log

# defaults: one plain file per domain/key under $T/prefs.
cat > "$T/bin/defaults" <<'SH'
#!/bin/bash
echo "defaults $*" >> "$CALLS"
f="$PREFS/$2.$3"
case $1 in
  read) [ -f "$f" ] && cat "$f" || exit 1 ;;
  write) [ "$4" = -int ] && echo "$5" > "$f" ;;
  delete) rm -f "$f" ;;
esac
SH
for c in killall open osascript logger pgrep; do
  printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n%s\n' "$c" "$([ "$c" = pgrep ] && echo 'exit 1' || echo 'exit 0')" > "$T/bin/$c"
done
printf '#!/bin/bash\necho "app $*" >> "$CALLS"\n' > "$T/dest/Shepetal.app/Contents/MacOS/Shepetal"
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
[ "$(grep -c '^defaults write' "$LOG")" = 2 ] || fail "expected exactly two writes (old value, new value)"
grep '^defaults write' "$LOG" | grep -v -e 'com.apple.HIToolbox AppleFnUsageType -int 0' -e 'io.backant.shepetal previousAppleFnUsageType' \
  && fail "wrote some other setting"
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

# 4. Absent key: stored as -1, uninstall deletes the key again.
rm -f "$PREFS"/*
post
[ "$(pref io.backant.shepetal.previousAppleFnUsageType)" = -1 ] || fail "absent key not stored as -1"

# 5. Uninstall against the stand-ins (SHEPETAL_APPS_DIR keeps it away from the real /Applications): restores and keeps data.
mkdir -p "$T/home/Library/Application Support/Shepetal" "$T/home/Applications/Shepetal.app/Contents/MacOS"
cp "$T/dest/Shepetal.app/Contents/MacOS/Shepetal" "$T/home/Applications/Shepetal.app/Contents/MacOS/"
echo 3 > "$PREFS/io.backant.shepetal.previousAppleFnUsageType"
: > "$LOG"
mkdir -p "$T/sysapps"
HOME=$T/home SHEPETAL_APPS_DIR=$T/sysapps bash scripts/uninstall-mac.sh > "$T/out.log" 2>&1 || fail "uninstall failed: $(cat "$T/out.log")"
[ "$(pref com.apple.HIToolbox.AppleFnUsageType)" = 3 ] || fail "uninstall did not restore 3"
[ "$(pref io.backant.shepetal.previousAppleFnUsageType)" = unset ] || fail "uninstall kept the stored value"
grep -qx "app --unregister-login-item" "$LOG" || fail "uninstall left the login item"
grep -qx "killall -9 TextInputSwitcher" "$LOG" || fail "uninstall did not restart TextInputSwitcher"
[ ! -e "$T/home/Applications/Shepetal.app" ] || fail "uninstall left ~/Applications/Shepetal.app"
[ -d "$T/home/Library/Application Support/Shepetal" ] || fail "uninstall deleted the recordings"
echo "ok: uninstall restores the 🌐 key, removes the login item and the app, keeps recordings and history"
echo "test-pkg-scripts: OK"
