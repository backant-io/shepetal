# shepetal for Linux

Hold fn to talk, double-tap it for hands-free, and the text is typed at the cursor.
Works on X11 and Wayland. Speech-to-text runs locally: Parakeet with sherpa-onnx, or Whisper with
whisper.cpp on Vulkan GPUs, as the tier table in `docs/models.md` picks.

Design, X11/Wayland matrix, packaging and manual test steps: [docs/linux.md](../docs/linux.md).

## Build and test in Docker

From the repo root (works on a Mac, no Rust toolchain needed):

```sh
docker run --rm -v "$PWD":/src -w /src/linux -e CARGO_TARGET_DIR=/tmp/target ubuntu:24.04 sh -c \
  'apt-get update -qq && apt-get install -y -qq cargo >/dev/null && cargo test && cargo build --release && /tmp/target/release/shepetal probe --pw-dump fixtures/pw-dump-meeting.json'
```

Ubuntu 24.04 ships cargo 1.75, so `Cargo.lock` is kept at lockfile version 3, which that cargo can read.
```

This runs the unit tests (gesture timing, model choice from the tier table, insertion backend
priority, text over stdin to fake typing tools, meeting detection over
`fixtures/pw-dump-meeting.json`, evdev decoding and the daemon's key event mapping and timing, the
sysfs key bitmap that finds fn, the daemon's fn default and keyboard choice over a fake sysfs,
cancelled and too-short clips kept, the short-press hint, a dictation through fake `pw-record`,
`sherpa-onnx-offline` and `wtype` that keeps the clip the model read, and the recorder stopped
when every keyboard closes), builds the release binary and runs `probe` against the fixture. The
real hotkey, mic, speech-to-text and typing tools need a real desktop and are not exercised in Docker.

## 🤫 indicator

`shepetal daemon` starts `indicator/shepetal-indicator` (GTK 3, X11 and wlr-layer-shell) from
PATH; on GNOME Wayland, `gnome-extension/` draws 🤫 instead. Its checks, including real X11 (Xvfb)
and Sway runs with screenshots, run in Docker from the repo root:

```sh
linux/indicator/check.sh            # prints where the screenshots went
```

Design, IPC and manual steps: [docs/linux.md, "🤫 indicator"](../docs/linux.md#-indicator).

## Run on a desktop

```sh
sudo usermod -aG input $USER              # then log out and in: evdev needs /dev/input access
sudo apt install pipewire-bin wtype xdotool ydotool wl-clipboard xclip   # whichever apply
sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-gtklayershell-0.1 fonts-noto-color-emoji
ln -s "$PWD/indicator/shepetal-indicator" ~/.local/bin/   # the daemon starts it from PATH
# sherpa-onnx-offline (or whisper-cli on Vulkan) on PATH, and the model `probe` names
# in ~/.local/share/shepetal/ (see docs/linux.md, manual test step 2)
cargo build --release
./target/release/shepetal probe          # hardware, model, insertion backend, mic users, fn visible?
./target/release/shepetal daemon         # exits with a hint if fn is not visible
SHEPETAL_KEY=rightalt ./target/release/shepetal daemon   # another key when fn is not visible
```
