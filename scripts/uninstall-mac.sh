#!/bin/bash
# Uninstalls Shepetal: quits it, turns Start at login off, puts back the "Press 🌐 key to" setting it
# replaced, and removes /Applications/Shepetal.app (and an old ~/Applications copy).
# Your recordings and history in ~/Library/Application Support/Shepetal are KEPT unless you pass
# --delete-data. Also shipped inside the app: /Applications/Shepetal.app/Contents/Resources/uninstall.sh
#
# The installer puts the app in /Applications owned by root, so removing it may need your admin
# password: macOS then asks for it in its own dialog. The script says plainly if the app is still there.
#
#   uninstall-mac.sh [--delete-data] [--dry-run]
set -uo pipefail
DELETE_DATA=0; DRY=0
for a in "$@"; do
  case $a in
    --delete-data) DELETE_DATA=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done
do_() { if [ "$DRY" = 1 ]; then echo "dry-run: $*"; else "$@"; fi; }

# Only bundles that really are Shepetal (bundle ID io.backant.shepetal).
APPS=()
for a in "${SHEPETAL_APPS_DIR:-/Applications}/Shepetal.app" "$HOME/Applications/Shepetal.app"; do
  [ -d "$a" ] || continue
  if [ "$(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null)" = io.backant.shepetal ]; then APPS+=("$a")
  else echo "Skipping $a: not Shepetal (bundle ID $(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null || echo unknown))"; fi
done

# Quit the running copies of those bundles: the normal way first, then SIGTERM.
running() { for a in ${APPS[@]+"${APPS[@]}"}; do pgrep -qf "^$a/Contents/MacOS/Shepetal" && return 0; done; return 1; }
if running; then
  if [ "$DRY" = 1 ]; then echo "dry-run: osascript -e 'quit app \"Shepetal\"'"
  else
    osascript -e 'quit app "Shepetal"' >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do running || break; sleep 0.25; done
    for a in ${APPS[@]+"${APPS[@]}"}; do pkill -f "^$a/Contents/MacOS/Shepetal" 2>/dev/null; done
  fi
fi

# Start at login off, while the app is still there to ask.
for a in ${APPS[@]+"${APPS[@]}"}; do do_ "$a/Contents/MacOS/Shepetal" --unregister-login-item; done

# The 🌐 key: put back what Shepetal replaced (-1: the key was absent).
PREV=$(defaults read io.backant.shepetal previousAppleFnUsageType 2>/dev/null) || PREV=
if [ -n "$PREV" ]; then
  if [ "$PREV" = -1 ]; then do_ defaults delete com.apple.HIToolbox AppleFnUsageType
  else do_ defaults write com.apple.HIToolbox AppleFnUsageType -int "$PREV"; fi
  do_ killall TextInputMenuAgent 2>/dev/null
  do_ killall -9 TextInputSwitcher 2>/dev/null
  do_ defaults delete io.backant.shepetal previousAppleFnUsageType
  echo "🌐 key setting restored (AppleFnUsageType ${PREV/-1/unset})"
else
  echo "🌐 key setting left as it is (Shepetal did not change it)"
fi

LEFT=()
for a in ${APPS[@]+"${APPS[@]}"}; do
  if [ "$DRY" = 1 ]; then echo "dry-run: rm -rf $a"; continue; fi
  rm -rf "$a" 2>/dev/null
  if [ -e "$a" ]; then
    # Installed by the .pkg, so owned by root: ask macOS for admin rights for this one removal.
    osascript -e 'on run argv' -e 'do shell script "rm -rf " & quoted form of (item 1 of argv) with administrator privileges' \
      -e 'end run' "$a" >/dev/null 2>&1 || true
  fi
  if [ -e "$a" ]; then LEFT+=("$a"); else echo "Removed $a"; fi
done
if pkgutil --pkgs 2>/dev/null | grep -qx io.backant.shepetal.pkg; then
  echo "The installer receipt stays (removing it needs admin rights: sudo pkgutil --forget io.backant.shepetal.pkg)"
fi

DATA="$HOME/Library/Application Support/Shepetal"
if [ "$DELETE_DATA" = 1 ]; then
  do_ rm -rf "$DATA" && [ "$DRY" = 0 ] && echo "Deleted $DATA"
  do_ defaults delete io.backant.shepetal 2>/dev/null
else
  [ -d "$DATA" ] && echo "Kept your recordings and history in $DATA (pass --delete-data to remove them)"
fi

if [ "$DRY" = 1 ]; then echo "Dry run: nothing was changed."; exit 0; fi
if [ ${#LEFT[@]} -gt 0 ]; then
  echo "NOT fully uninstalled: could not remove ${LEFT[*]}. Drag it to the Trash in Finder (it asks for your password), then empty the Trash." >&2
  exit 1
fi
echo "Shepetal is uninstalled."
