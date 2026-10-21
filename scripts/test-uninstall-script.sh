#!/bin/bash
# Tests scripts/uninstall-mac.sh (the fallback for an app that won't open; the app's own is Settings > Uninstall
# Shepetal…) against stand-ins for `defaults`, `killall`, `open`, `osascript`, `pkill` and the app, so the real 🌐 key
# setting, login items and apps are never touched.
#   scripts/test-uninstall-script.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
[ "$(id -u)" != 0 ] || { echo "run as a normal user: as root the scripts switch users and would reach the real defaults" >&2; exit 1; }
mkdir -p "$ROOT/.cache"
T=$(mktemp -d "$ROOT/.cache/uninstall-test.XXXXXX")
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
pref() { cat "$PREFS/$1" 2>/dev/null || echo unset; }

# 4. The key was absent before Shepetal (stored as -1): the uninstaller deletes it again.
echo 0 > "$PREFS/com.apple.HIToolbox.AppleFnUsageType"
echo -1 > "$PREFS/io.backant.shepetal.previousAppleFnUsageType"
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
echo "test-uninstall-script: OK"
