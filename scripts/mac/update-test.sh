#!/bin/bash
# Sparkle end to end on a clean Mac (docs/update-test.md), run by .github/workflows/update.yml: version N is installed,
# Sparkle's own sparkle-cli updates it to N+1 from a local feed, a DMG with one flipped byte is refused, and an
# appcast offering a lower build installs nothing. Ad-hoc signed, with a throwaway Sparkle key made here.
#
#   CI=true scripts/mac/update-test.sh <sparkle-dir>   <sparkle-dir>: Sparkle's release tarball, extracted, with
#                                                       bin/sparkle.app (sparkle-cli) built from the same version
#   PORT=8765 ...                                       the local feed's port
#
# It resets io.backant.shepetal's preferences and Sparkle's caches, so it refuses to run outside CI.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${CI:-}" = true ] || { echo "update-test.sh resets io.backant.shepetal's preferences: run it on a throwaway Mac (CI=true)" >&2; exit 2; }
SP=$(cd "${1:?usage: update-test.sh <sparkle-dir>}" && pwd)
CLI=$(find "$SP" -path '*/sparkle.app/Contents/MacOS/sparkle' -type f | head -1)
[ -x "$CLI" ] || { echo "no sparkle.app (sparkle-cli) in $SP" >&2; exit 2; }
PORT=${PORT:-8765}
T=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/update-test.XXXXXX")
FEED=http://127.0.0.1:$PORT/appcast.xml
V_N=0.0.1 V_N1=0.0.2
B_N=$(git rev-list --count HEAD); B_N1=$((B_N + 1))
step() { printf '\n== %s\n' "$*"; }
fail() { echo "::error::$*"; exit 1; }
plist() { plutil -extract "$1" raw "$2/Contents/Info.plist"; }

step "a throwaway Sparkle EdDSA key (never the real one)"
export SIGN_IDENTITY=- SHEPETAL_TEST_FEED_URL=$FEED UPDATES=1 REQUIRE_SIGNIN=1
export SPARKLE_PUBLIC_KEY; SPARKLE_PUBLIC_KEY=$(swift scripts/mac/verify-update.swift --throwaway-key "$T/ed.key")
[ "$SPARKLE_PUBLIC_KEY" != aXU+sm8y+UDKwB2M7DxhacVN/BAgTqMsHq2rMc3fibs= ] || fail "the throwaway key is the release key"
echo "public key $SPARKLE_PUBLIC_KEY"

step "version N: $V_N, build $B_N"
VERSION=$V_N SHEPETAL_TEST_BUILD=$B_N scripts/make-app.sh
mkdir -p "$T/N"; ditto dist/Shepetal.app "$T/N/Shepetal.app"

step "version N+1: $V_N1, build $B_N1, as a DMG (scripts/make-dmg.sh)"
VERSION=$V_N1 SHEPETAL_TEST_BUILD=$B_N1 scripts/make-dmg.sh
DMG=dist/Shepetal-$V_N1.dmg
for a in "$T/N/Shepetal.app" dist/Shepetal.app; do
  echo "$a: $(plist CFBundleShortVersionString "$a") build $(plist CFBundleVersion "$a"), feed $(plist SUFeedURL "$a")"
  [ "$(plist SUFeedURL "$a")" = "$FEED" ] || fail "$a does not point at the local feed"
  [ "$(plist SUPublicEDKey "$a")" = "$SPARKLE_PUBLIC_KEY" ] || fail "$a does not carry the throwaway key"
done

step "the appcast, the way release.sh writes it (generate_appcast), and sign_update's signature"
WWW=$T/www DL=download/$V_N1/Shepetal-$V_N1.dmg
mkdir -p "$T/archives" "$WWW/download/$V_N1"
cp "$DMG" "$T/archives/"; cp "$DMG" "$WWW/$DL"; cp "$DMG" "$T/good.dmg"
"$SP/bin/generate_appcast" --ed-key-file "$T/ed.key" --maximum-deltas 0 \
  --download-url-prefix "${FEED%appcast.xml}download/$V_N1/" -o "$WWW/appcast.xml" "$T/archives"
cat "$WWW/appcast.xml"
SIG=$("$SP/bin/sign_update" --ed-key-file "$T/ed.key" "$DMG")
echo "sign_update: $SIG"
for part in $SIG; do  # sparkle:edSignature="..." length="...", in another order in the appcast
  grep -qF "$part" "$WWW/appcast.xml" || fail "sign_update's $part is not in the appcast"
done
grep -qF "url=\"${FEED%appcast.xml}$DL\"" "$WWW/appcast.xml" || fail "the appcast does not offer ${FEED%appcast.xml}$DL"
grep -q "<sparkle:version>$B_N1</sparkle:version>" "$WWW/appcast.xml" || fail "the appcast is not for build $B_N1"
swift scripts/mac/verify-update.swift "$WWW/appcast.xml" "$DMG" dist/Shepetal.app/Contents/Info.plist
cp "$WWW/appcast.xml" "$T/appcast.good.xml"

step "the local feed: python3 -m http.server on 127.0.0.1:$PORT"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WWW" >> "$T/http.log" 2>&1 &  # appended, so update() can empty it
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -fsS -o /dev/null "$FEED" 2>/dev/null && break; sleep 0.2; done
curl -fsS -o /dev/null "$FEED" || fail "the local feed does not answer"

APPS=$T/Applications APP=$T/Applications/Shepetal.app
install_n() {
  rm -rf "$APP"; mkdir -p "$APPS"; ditto "$T/N/Shepetal.app" "$APP"
  # A clean slate for Sparkle: no last check time, no skipped version, no download left from a previous run.
  defaults delete io.backant.shepetal >/dev/null 2>&1 || true
  rm -rf ~/Library/Caches/io.backant.shepetal ~/Library/Caches/org.sparkle-project.Sparkle*
  echo "installed $APP: $(plist CFBundleShortVersionString "$APP") build $(plist CFBundleVersion "$APP")"
  [ "$(plist CFBundleVersion "$APP")" = "$B_N" ] || fail "the installed app is not build $B_N"
}
RC=0
update() {  # sparkle-cli, non-interactive, against the installed bundle; its output in $T/$1.log
  : > "$T/http.log"
  RC=0
  perl -e 'alarm shift; exec @ARGV' 300 "$CLI" --check-immediately --verbose "$APP" > "$T/$1.log" 2>&1 || RC=$?
  sed 's/^/  sparkle: /' "$T/$1.log"
  echo "sparkle-cli exited $RC; the feed served:"; sed 's/^/  http: /' "$T/http.log"
}
wait_build() {  # the installer finishes after sparkle-cli returns
  for _ in $(seq 1 120); do [ "$(plist CFBundleVersion "$APP" 2>/dev/null)" = "$1" ] && return 0; sleep 1; done
  return 1
}

step "install N, then update it with sparkle-cli"
install_n
update update
wait_build "$B_N1" || fail "the installed app is build $(plist CFBundleVersion "$APP" 2>/dev/null), not $B_N1, after the update"
[ "$(plist CFBundleShortVersionString "$APP")" = "$V_N1" ] || fail "the installed app is not version $V_N1"
grep -q "GET /$DL" "$T/http.log" || fail "the update was not downloaded from the local feed"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | sed 's/^/  codesign: /'
echo "PASS: N ($V_N, build $B_N) was updated to N+1 ($V_N1, build $B_N1) and its signature verifies"

step "a tampered DMG: one byte flipped, same appcast, same signature"
install_n
python3 -I - "$WWW/$DL" <<'PY'
import os, sys
p = sys.argv[1]
with open(p, "r+b") as f:
    f.seek(os.path.getsize(p) // 2)
    b = f.read(1)
    f.seek(-1, 1)
    f.write(bytes([b[0] ^ 0x01]))
PY
cmp -l "$T/good.dmg" "$WWW/$DL" | sed 's/^/  cmp: /' || true
[ "$(stat -f %z "$WWW/$DL")" = "$(stat -f %z "$T/good.dmg")" ] || fail "the tampered DMG changed length"
update tampered
sleep 10  # an installer that should not run would have started by now
grep -q "GET /$DL" "$T/http.log" || fail "the tampered DMG was never downloaded, so its signature was never checked"
# Sparkle 2 checks the signature in its installer and reports a refused update to sparkle-cli as SUInstallationError,
# 4005 in SUSparkleErrorDomain (SUErrors.h); sparkle-cli prints it as "error 4005
# (SUSparkleErrorDomain)". The sentence around the code is Sparkle's and can change; the code and domain are matched.
grep -F '4005 (SUSparkleErrorDomain)' "$T/tampered.log" ||
  fail "sparkle-cli did not report error 4005 (SUSparkleErrorDomain) for the tampered DMG"
[ "$(plist CFBundleVersion "$APP")" = "$B_N" ] || fail "the tampered DMG was installed: build $(plist CFBundleVersion "$APP")"
codesign --verify --deep --strict "$APP"
echo "PASS: the tampered DMG was refused and N (build $B_N) is still installed"

step "no downgrade: the appcast offers build $((B_N - 1)), lower than the installed $B_N"
install_n
cp "$T/good.dmg" "$WWW/$DL"
sed -e "s|<sparkle:version>$B_N1</sparkle:version>|<sparkle:version>$((B_N - 1))</sparkle:version>|" \
  -e "s|<sparkle:shortVersionString>$V_N1</sparkle:shortVersionString>|<sparkle:shortVersionString>0.0.0</sparkle:shortVersionString>|" \
  "$T/appcast.good.xml" > "$WWW/appcast.xml"
grep -q "<sparkle:version>$((B_N - 1))</sparkle:version>" "$WWW/appcast.xml" || fail "the downgrade appcast was not written"
update downgrade
sleep 10
grep -q 'GET /appcast.xml' "$T/http.log" || fail "sparkle-cli never read the feed"
if grep -q "GET /$DL" "$T/http.log"; then fail "sparkle-cli downloaded a lower build"; fi
[ "$(plist CFBundleVersion "$APP")" = "$B_N" ] || fail "a lower build was installed: build $(plist CFBundleVersion "$APP")"
echo "PASS: a lower build in the appcast was not installed; N (build $B_N) is still installed"

printf '\n== update test passed: N installed, updated to N+1, tampered DMG refused, no downgrade\n'
