#!/bin/sh
# Builds target/debian/shepetal_<version>-1_<arch>.deb with cargo-deb (cargo install cargo-deb).
# Run from anywhere. The deb settings live in deb.toml, merged into a staged copy of Cargo.toml.
set -eu
linux=$(cd "$(dirname "$0")/.." && pwd)
stage="$linux/target/deb-stage"
rm -rf "$stage"
mkdir -p "$stage"
for f in src fixtures packaging README.md Cargo.lock; do ln -s "$linux/$f" "$stage/$f"; done
cat "$linux/Cargo.toml" "$linux/packaging/deb.toml" > "$stage/Cargo.toml"
ln -s "$linux/../LICENSE" "$stage/LICENSE"
CARGO_TARGET_DIR="$linux/target" cargo deb --manifest-path "$stage/Cargo.toml" --locked \
    --output "$linux/target/debian/" "$@"
