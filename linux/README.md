# shepetal for Linux

Hold fn to talk, double-tap it for hands-free, and the text is typed at the cursor.
Works on X11 and Wayland. Speech-to-text runs locally with whisper.cpp.

Design, X11/Wayland matrix, packaging and manual test steps: [docs/linux.md](../docs/linux.md).

## Build and test in Docker

From the repo root (works on a Mac, no Rust toolchain needed):

```sh
docker run --rm -v "$PWD/linux":/src -w /src -e CARGO_TARGET_DIR=/tmp/target ubuntu:24.04 sh -c \
  'apt-get update -qq && apt-get install -y -qq cargo >/dev/null && cargo test && cargo build --release && /tmp/target/release/shepetal probe --pw-dump fixtures/pw-dump-meeting.json'
```

Ubuntu 24.04 ships cargo 1.75, so `Cargo.lock` is kept at lockfile version 3, which that cargo can read.
```

This runs the unit tests (gesture timing, model choice, insertion backend priority, text over
stdin to fake typing tools, meeting detection over `fixtures/pw-dump-meeting.json`, evdev
decoding, the sysfs key bitmap that finds fn, the daemon's fn default and keyboard choice over a
fake sysfs, cancelled and too-short clips kept, the short-press hint), builds the release binary and
runs `probe` against the fixture. The hotkey, mic, whisper-cli and typing paths need a real
desktop and are not exercised in Docker.

## Run on a desktop

```sh
sudo usermod -aG input $USER              # then log out and in: evdev needs /dev/input access
sudo apt install pipewire-bin wtype xdotool ydotool wl-clipboard xclip   # whichever apply
# whisper-cli from whisper.cpp on PATH, model in ~/.local/share/shepetal/ggml-<model>.bin
cargo build --release
./target/release/shepetal probe          # hardware, model, insertion backend, mic users, fn visible?
./target/release/shepetal daemon         # exits with a hint if fn is not visible
SHEPETAL_KEY=rightalt ./target/release/shepetal daemon   # another key when fn is not visible
```
