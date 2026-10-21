#!/bin/bash
# Builds the installer dist/Shepetal-<version>.pkg (pkgbuild + productbuild) from dist/Shepetal.app:
# it installs Shepetal.app to /Applications, then its postinstall (as the logged-in user) sets
# "Press 🌐 key to" to Do Nothing, turns on Start at login and opens the app (scripts/pkg/).
#
#   scripts/make-pkg.sh           runs scripts/make-app.sh, then writes dist/Shepetal-<version>.pkg
#   scripts/make-pkg.sh --test    a test package that changes nothing: its app is a copy with bundle ID
#                                 io.backant.shepetal.check, it installs under ~/shepetal-agent/tmp/pkgtest
#                                 (installer -target CurrentUserHomeDirectory) and its scripts only print
#                                 what they would do
#   VERSION=0.1.1 ...             version (default 0.1.0)
#   REQUIRE_SIGNIN=0 ...          a package whose app dictates without sign-in (default 1, see make-app.sh)
#   INSTALLER_IDENTITY=<name>     sign the package (needs a "Developer ID Installer" identity; unsigned without)
set -euo pipefail
cd "$(dirname "$0")/.."
TEST=0
[ "${1:-}" = --test ] && TEST=1
VERSION=${VERSION:-0.1.0}
export VERSION
export REQUIRE_SIGNIN=${REQUIRE_SIGNIN:-1}  # the release requires sign-in
[ "${SKIP_APP:-0}" = 1 ] || scripts/make-app.sh

WORK=.cache/pkg
rm -rf "$WORK"
mkdir -p "$WORK/root" "$WORK/scripts"
ditto dist/Shepetal.app "$WORK/root/Shepetal.app"
cp scripts/pkg/preinstall scripts/pkg/postinstall "$WORK/scripts/"
chmod 755 "$WORK/scripts/"*
ID=io.backant.shepetal
LOCATION=/Applications
DOMAINS='enable_localSystem="true"'
OUT=dist/Shepetal-$VERSION.pkg
if [ "$TEST" = 1 ]; then
  ID=io.backant.shepetal.check
  plutil -replace CFBundleIdentifier -string "$ID" "$WORK/root/Shepetal.app/Contents/Info.plist"
  codesign --force --deep --sign - --identifier "$ID" "$WORK/root/Shepetal.app" 2>/dev/null
  touch "$WORK/scripts/dry-run"
  LOCATION=/shepetal-agent/tmp/pkgtest  # relative to the home folder with -target CurrentUserHomeDirectory
  DOMAINS='enable_currentUserHome="true"'
  OUT=dist/Shepetal-$VERSION-test.pkg
fi

# Not relocatable: the installer must write to /Applications, never "update" a copy found elsewhere.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --identifier "$ID.pkg" \
  --version "$VERSION" --install-location "$LOCATION" --scripts "$WORK/scripts" "$WORK/Shepetal-component.pkg"

cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Shepetal $VERSION</title>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <domains $DOMAINS/>
  <volume-check><allowed-os-versions><os-version min="14.0"/></allowed-os-versions></volume-check>
  <welcome mime-type="text/plain"><![CDATA[Shepetal: local dictation for your Mac. Hold fn and talk; the text lands where your cursor is. Speech-to-text runs on this Mac, nothing you say leaves it.

This installs Shepetal.app to /Applications. Afterwards it:
- sets System Settings > Keyboard > "Press 🌐 key to" to Do Nothing, so fn dictates instead of switching the input source (the 🤫 menu can restore your old setting),
- turns on Start at login,
- opens Shepetal. Then grant Microphone, Input Monitoring and Accessibility in its permissions window.

Your recordings and history stay in ~/Library/Application Support/Shepetal. MIT licensed: https://github.com/backant-io/shepetal]]></welcome>
  <choices-outline><line choice="default"><line choice="$ID.pkg"/></line></choices-outline>
  <choice id="default"/>
  <choice id="$ID.pkg" visible="false"><pkg-ref id="$ID.pkg"/></choice>
  <pkg-ref id="$ID.pkg" version="$VERSION" onConclusion="none">Shepetal-component.pkg</pkg-ref>
</installer-gui-script>
XML

SIGN=()
[ -n "${INSTALLER_IDENTITY:-}" ] && SIGN=(--sign "$INSTALLER_IDENTITY")
productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" ${SIGN[@]+"${SIGN[@]}"} "$OUT"
(cd dist && shasum -a 256 "$(basename "$OUT")" | tee "$(basename "$OUT").sha256")
pkgutil --check-signature "$OUT" | head -1 || true
echo "Built $PWD/$OUT"
