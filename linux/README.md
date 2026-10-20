# shepetal for Linux

Hold Right Ctrl to talk, double-tap it for hands-free, and the text is typed at the cursor.
Works on X11 and Wayland. Speech-to-text runs locally with whisper.cpp.

Design, X11/Wayland matrix, packaging and manual test steps: [docs/linux.md](../docs/linux.md).

## Build and test in Docker

From the repo root (works on a Mac, no Rust toolchain needed):

```sh
docker run --rm -v "$PWD/linux":/src -w /src -e CARGO_TARGET_DIR=/tmp/target rust:1-slim \
  sh -c 'cargo test && cargo build --release && /tmp/target/release/shepetal probe --pw-dump fixtures/pw-dump-meeting.json'
```

This runs the unit tests (gesture timing, model choice, insertion backend priority, meeting
detection over `fixtures/pw-dump-meeting.json`, evdev decoding), builds the release binary and
runs `probe` against the fixture. The hotkey, mic, whisper-cli and typing paths need a real
desktop and are not exercised in Docker.

## Run on a desktop

```sh
sudo usermod -aG input $USER              # then log out and in: evdev needs /dev/input access
sudo apt install pipewire-bin wtype xdotool ydotool wl-clipboard xclip   # whichever apply
# whisper-cli from whisper.cpp on PATH, model in ~/.local/share/shepetal/ggml-<model>.bin
cargo build --release
./target/release/shepetal probe          # hardware, chosen model, insertion backend, mic users
./target/release/shepetal daemon         # SHEPETAL_KEY=rightalt to change the key
```
