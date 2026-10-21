#!/bin/sh
# Builds target/appimage/shepetal-<version>-x86_64.AppImage.
# Uses $APPIMAGETOOL when set, else downloads the pinned appimagetool and checks its sha256.
set -eu
linux=$(cd "$(dirname "$0")/.." && pwd)
pkg="$linux/packaging"
out="$linux/target/appimage"
appdir="$out/shepetal.AppDir"
version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$linux/Cargo.toml" | head -1)

tool_version=1.9.1
tool_sha256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0

cargo build --release --locked --manifest-path "$linux/Cargo.toml"
target_dir=${CARGO_TARGET_DIR:-$linux/target}

rm -rf "$appdir"
mkdir -p "$appdir/usr/bin" "$appdir/usr/share/shepetal" "$appdir/usr/share/applications" \
    "$appdir/usr/share/icons/hicolor/scalable/apps"
install -m 755 "$target_dir/release/shepetal" "$appdir/usr/bin/shepetal"
install -m 755 "$pkg/AppRun" "$appdir/AppRun"
install -m 644 "$pkg/shepetal.service" "$appdir/usr/share/shepetal/shepetal.service"
install -m 644 "$pkg/shepetal.svg" "$appdir/usr/share/icons/hicolor/scalable/apps/shepetal.svg"
cp "$pkg/shepetal.svg" "$appdir/shepetal.svg"
# The deb's entry starts the installed unit; the AppImage starts itself.
sed 's/^Exec=.*/Exec=shepetal/' "$pkg/shepetal.desktop" > "$appdir/shepetal.desktop"
cp "$appdir/shepetal.desktop" "$appdir/usr/share/applications/shepetal.desktop"

tool=${APPIMAGETOOL:-}
if [ -z "$tool" ]; then
    tool="$out/appimagetool-$tool_version"
    if [ ! -x "$tool" ]; then
        curl -fsSL -o "$tool.part" \
            "https://github.com/AppImage/appimagetool/releases/download/$tool_version/appimagetool-x86_64.AppImage"
        echo "$tool_sha256  $tool.part" | sha256sum -c - >/dev/null
        chmod 755 "$tool.part"
        mv "$tool.part" "$tool"
    fi
fi
# appimagetool is an AppImage itself; extracting it avoids needing FUSE on CI runners.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 VERSION="$version" "$tool" --no-appstream \
    "$appdir" "$out/shepetal-$version-x86_64.AppImage"
echo "$out/shepetal-$version-x86_64.AppImage"
