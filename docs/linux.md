# shepetal on Linux

Status: v0 scaffold. The pure logic is unit-tested in Docker. The device paths (hotkey, mic,
speech-to-text, typing) are written but have not been run on a real desktop yet.

## Language: Rust

- One static-ish binary, no runtime to install. That matters for an AppImage or `.deb`.
- The ecosystem has what the later versions need: `evdev`, `pipewire-rs`, `whisper-rs`
  (whisper.cpp bindings with CUDA and Vulkan features) and `sherpa-rs`.
- Raw evdev reading is about twenty lines with the standard library, so v0 has a single
  dependency (`serde_json`) and builds in seconds in Docker.

I found no strong reason against Rust. Go would also give one binary, but its whisper.cpp and
PipeWire bindings are less mature. Python would need a runtime and a virtualenv on every machine.

## Stack (v0)

| Part | v0 | Later |
| --- | --- | --- |
| Hotkey | fn (evdev `KEY_FN`). Read only the `/dev/input/event*` keyboards whose sysfs key capabilities include the hotkey (see "fn hotkey" below). Their key events go to one state machine. User must be in the `input` group. | GlobalShortcuts portal first (press and release, GNOME 48+, Plasma, Hyprland), evdev as the opt-in fallback, `evdev` crate for hotplug |
| Gesture | Recording starts on the fn press. Hold fn at least 500 ms for push-to-talk. Two taps with at most 500 ms between the release and the second press for hands-free, next press stops. A shorter press with no second tap is too short: nothing is transcribed or typed, the clip is kept as too short, and the daemon prints the hint `Hold fn to talk · double-tap for hands-free` to stderr (the 🤫 overlay will show it). A chord (fn+F1) cancels without a hint, and the clip is kept as cancelled. The 500/500 ms values match the Mac (`Sources/ShepetalCore/FnGesture.swift`) and the 500 ms debounce in `docs/re/dictation-input.md` section 2.3. Set another key with `SHEPETAL_KEY` (`rightalt`, `rightmeta`, `capslock`, `f13`, `rightctrl` or an evdev code). | Config file, tunable thresholds |
| Mic | `pw-record` at 16 kHz mono s16, falling back to `parecord` (PulseAudio). Stopped with SIGINT so the WAV header is written. | `pipewire-rs` stream, no temp file |
| STT | `sherpa-onnx-offline` (Parakeet) or `whisper-cli` from whisper.cpp (Whisper), run on the kept WAV. sherpa-onnx prints one JSON line per file on stdout, and shepetal reads its `text`. | `sherpa-rs` / `whisper-rs` in-process, model kept warm, sherpa-onnx streaming for meetings |
| Model | The Linux rows of the tier table in `docs/models.md` (goal rule 5). CPU: Parakeet TDT 0.6B v3 int8 on sherpa-onnx, or Parakeet TDT-CTC 110M int8 below 4 GB RAM. CUDA (`/dev/nvidia0`, 8 GB RAM or more): Parakeet TDT 0.6B v3 with `--provider=cuda`. Vulkan (an ICD in `/usr/share/vulkan/icd.d`, 8 GB RAM or more): Whisper large-v3-turbo q5_0 on whisper.cpp. | Thresholds from measured latency, VRAM check, the Whisper fallback for languages Parakeet lacks |
| Insert | See the matrix below | RemoteDesktop portal (`persist_mode=2`) on GNOME and KDE, clipboard plus paste key with restore for long text |
| Meeting | Parse `pw-dump`: running `Stream/Input/Audio` nodes that do not capture a sink monitor, matched to Zoom, Teams, Slack, Discord, Chrome/Chromium, Firefox. System audio is `<default.audio.sink>.monitor` from the `default` metadata. | Live `pw-dump --monitor`, record the monitor next to the mic |

`shepetal probe` prints all of this for the current machine. `shepetal daemon` runs the loop.

## X11 / Wayland matrix

The order in which the insertion backend is chosen, from `XDG_SESSION_TYPE` and `XDG_CURRENT_DESKTOP`:

| Session | 1st | 2nd | Last resort |
| --- | --- | --- | --- |
| X11 (any desktop) | `xdotool type` | `ydotool type` | `xclip` (text left on the clipboard) |
| Wayland, wlroots (Sway, Hyprland) and KDE | `wtype` | `ydotool type` | `wl-copy` (text left on the clipboard) |
| Wayland, GNOME | `ydotool type` (Mutter has no virtual-keyboard protocol, so `wtype` fails) | | `wl-copy` |

The hotkey works the same in every session because evdev sits below the display server.
`ydotool` needs `ydotoold` running and access to `/dev/uinput`, and it sends keycodes, so the
result depends on the keyboard layout.

The clipboard fallback does not restore the old clipboard. In that case nothing can send the
paste keystroke, so the user pastes by hand, and restoring the clipboard would delete the text first.

## Security

- Dictated text goes to `wtype -`, `xdotool type --file -`, `ydotool type --file -`, `wl-copy`
  and `xclip` over stdin. It never goes in argv, which every local user can read with `ps`.
- Every dictation's raw audio is kept, the exact 16 kHz mono WAV the model received, in
  `$XDG_DATA_HOME/shepetal/audio/` (default `~/.local/share/shepetal/audio/`). The directory is
  created 0700, and the daemon refuses to start if it is a symlink or open to other users. Each
  file is a new `<unix-ms>.wav`, created with `O_CREAT|O_EXCL` (which also refuses a symlink) and
  mode 0600. Nothing is deleted. A cancelled recording is renamed `<unix-ms>.cancelled.wav`, and
  a too-short press `<unix-ms>.tooshort.wav`.
  There is no option to skip storage. Audio never goes to `/tmp`, where another user could swap
  it and so choose what gets typed.
- Because an fn chord (fn+F1, fn+arrow) also counts as a cancelled recording, the history fills
  with short clips of whatever was said while the user pressed fn. Users should know this.
- Being in the `input` group lets a process read every keystroke. shepetal only acts on the
  hotkey and does not store or log other keys.

## fn hotkey

The default hotkey is fn. Linux only sees fn when the keyboard driver reports it as a key.
Apple keyboards do (hid-apple maps their fn usage to `KEY_FN`). Many laptops handle fn in
the keyboard firmware and never send it, so fn is invisible there and cannot be used.

- `KEY_FN` is `0x1d0` (464):
  [include/uapi/linux/input-event-codes.h#L530](https://github.com/torvalds/linux/blob/v7.3/include/uapi/linux/input-event-codes.h#L530).
- Apple's fn usage becomes `KEY_FN`:
  [drivers/hid/hid-apple.c#L732-L738](https://github.com/torvalds/linux/blob/v7.3/drivers/hid/hid-apple.c#L732-L738).
- A device cannot send a key its key bitmap does not declare. The input core drops it:
  [drivers/input/input.c#L235-L236](https://github.com/torvalds/linux/blob/v7.3/drivers/input/input.c#L235-L236).
- `/sys/class/input/eventN/device/capabilities/key` is written by `input_print_bitmap`
  ([drivers/input/input.c#L1557-L1600](https://github.com/torvalds/linux/blob/v7.3/drivers/input/input.c#L1557-L1600))
  with each word formatted by `input_bits_to_string`
  ([drivers/input/input-compat.c#L100-L120](https://github.com/torvalds/linux/blob/v7.3/drivers/input/input-compat.c#L100-L120)
  and [#L154-L159](https://github.com/torvalds/linux/blob/v7.3/drivers/input/input-compat.c#L154-L159)):
  - A word is one `unsigned long` printed as hex with `%lx`, without zero padding. It is
    64 bits on a 64-bit kernel. A 32-bit process on a 64-bit kernel gets each long as two
    32-bit words, so the word width is always the reading process's pointer width.
  - The most significant word comes first, separated by single spaces. Bit 0 is in the last word.
  - Leading zero words are dropped. Zero words after the first non-zero one are printed as `0`.
    An empty map is a single `0`.
  - So `KEY_FN` is bit 16 of word 7 counted from the end: `10000 0 0 0 ...` with 7 words after it.

At startup `shepetal daemon` reads that file for every `event*` node and listens only on the
keyboards whose bitmap includes the hotkey. If no device reports `KEY_FN` and `SHEPETAL_KEY` is
unset, it exits non-zero with a message saying fn is not visible to Linux and how to set
`SHEPETAL_KEY`. It never falls back to another key on its own. `shepetal probe` prints whether fn
is visible and on which devices (sysfs is world-readable, so this needs no `input` group).

The daemon and `probe` both skip the device named `ydotoold virtual device`. ydotoold (needed on GNOME Wayland) creates
a uinput keyboard that declares every key, `KEY_FN` included
([ydotool v1.0.4 ydotoold.c](https://github.com/ReimuNotMoe/ydotool/blob/v1.0.4/Daemon/ydotoold.c),
and libuInputPlus's default key list for 0.1.8), but it only replays what `ydotool type` sends.
Counted as a keyboard, it would let the daemon start on a laptop whose fn is invisible and then
wait for a key that never comes. The name is the only stable marker: ydotool 1.x registers the
device as `BUS_VIRTUAL`, but 0.1.8, the Ubuntu 24.04 package, registers it as `BUS_USB` (the
libuInputPlus default).

## Packaging

- **`.deb` / AppImage**: recommended. A plain process can read `/dev/input`, run `pw-record` and
  call `wtype`/`xdotool`/`ydotool`. The installer only has to add the user to the `input` group,
  and the `.deb` can depend on `pipewire-bin` and `wtype | xdotool`.
- **Flatpak**: a bad fit for v0. The sandbox has no `/dev/input` unless you set `--device=input`
  (Flatpak 1.15.6+) or `--device=all`, which Flathub reviewers push back on. Host binaries (`wtype`, `xdotool`) need
  `flatpak-spawn --host`, and global hotkeys inside the sandbox would mean the GlobalShortcuts
  portal plus the RemoteDesktop portal for typing. That is the planned Flatpak path; v0 does not
  have it. Research notes: `docs/re/mobile-and-platforms.md`, section 5.
- **Snap**: same problems as Flatpak, but `classic` confinement would work.
- Never ship model weights in the package. They download on first run into `~/.local/share/shepetal/`.

## Build and test

See [linux/README.md](../linux/README.md). It is one `docker run` that runs `cargo test`,
builds the release binary and runs `probe` against the committed `pw-dump` fixture.

## Manual test steps (real Ubuntu 24.04 desktop)

Not yet done. These are the steps:

1. `sudo apt install pipewire-bin wl-clipboard xclip xdotool ydotool cmake build-essential`,
   then `sudo usermod -aG input $USER` and log out and back in.
2. Install the speech-to-text runner and the model `shepetal probe` names, into
   `~/.local/share/shepetal/`:
   - Parakeet (CPU and CUDA): put `sherpa-onnx-offline` on PATH from the
     [sherpa-onnx v1.13.8 release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8)
     (`sherpa-onnx-v1.13.8-linux-x64-shared.tar.bz2`; for CUDA the `...-linux-x64-gpu.tar.bz2`
     that matches the CUDA version), then unpack
     `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2`
     there. A CPU-only build given `--provider=cuda` logs `Fallback to cpu!` and still works.
   - Whisper (Vulkan): build whisper.cpp with `-DGGML_VULKAN=ON`, put `build/bin/whisper-cli` on
     PATH and download `ggml-large-v3-turbo-q5_0.bin` there
     (`./models/download-ggml-model.sh large-v3-turbo-q5_0`).
3. `cargo build --release && ./target/release/shepetal probe`. Check that RAM, cores, the GPU
   and the insertion backend match the machine. On GNOME Wayland it must say `Ydotool`.
   Check the `fn key:` line. With an Apple keyboard it must say `visible on /dev/input/eventN`
   with the keyboard's name. If it says `not visible`, the keyboard handles fn in firmware:
   step 5 must fail with the fn message, and steps 6 to 9 then run with
   `SHEPETAL_KEY=rightalt ./target/release/shepetal daemon` and Right Alt in place of fn.
4. Start a Zoom call or a Google Meet in Firefox and run `probe` again. It must list the app as
   a mic user with `meeting=Some(..)`. Close the call, and it must disappear.
5. `ydotoold &` (GNOME Wayland only), then run `probe` again: its `fn key:` line must not
   change, and it must never name `ydotoold virtual device`. Then `./target/release/shepetal daemon`.
   It must print the keyboards it listens on. If fn is not visible, it must exit non-zero with
   the message that fn is not visible to Linux and how to set `SHEPETAL_KEY`, also while
   ydotoold runs.
6. Open gedit. Hold fn, say "hello world", release: the text appears. Recording starts on the
   press, so the first word is not cut off.
7. Tap fn once (shorter than half a second): nothing is typed, the daemon prints
   `shepetal: hint: Hold fn to talk · double-tap for hands-free` about half a second after the
   release, and a `<unix-ms>.tooshort.wav` appears in `~/.local/share/shepetal/audio/`. Press
   fn+F1 while talking: nothing is typed, no hint is printed, and a `<unix-ms>.cancelled.wav`
   appears there.
8. Double-tap fn, talk for 20 seconds while typing elsewhere, then press fn
   once: the whole passage is typed.
9. Repeat steps 6 to 8 in an X11 session ("Ubuntu on Xorg" at login), where it must use `xdotool`.
10. With fn visible: `SHEPETAL_KEY=rightalt ./target/release/shepetal daemon`. Right Alt now
    works and fn does nothing.

## Known gaps

- Transcription runs on the input thread, so keys pressed during it queue up. Each event is
  stamped when the loop takes it, so a hold that starts during a transcription is measured short.
- If every keyboard closes (a Bluetooth keyboard sleeps), the daemon stops a running recorder
  with SIGINT, keeps the clip as `*.cancelled.wav` and exits. A daemon killed by a signal
  (`kill`, SIGKILL) still leaves a running `pw-record` behind.
- Vulkan counts as present when `/usr/share/vulkan/icd.d` has any file, which includes Mesa's
  software renderer (lavapipe). Such a machine gets Whisper turbo on Vulkan, not Parakeet on CPU.
- Parakeet TDT-CTC 110M is English only. The 4 GB RAM line that picks it stands in for the
  table's "low-end ARM" and is not measured.
- No hotplug: keyboards plugged in after start are not seen.
- Only ydotoold's virtual device is skipped. Any other uinput device that declares fn still
  counts as an fn keyboard, so with one running and fn invisible the daemon starts and fn does
  nothing. Skipping every virtual device would also drop a remapper's (keyd) virtual keyboard,
  which is then the only device that sends real keys.
- Only keyboards that report the hotkey are read, so a key pressed on another keyboard while fn
  is held does not cancel.
- Whether `pw-record -P '{ application.name = shepetal }'` really renames the stream is not
  verified. If it does not, `probe` lists shepetal's own recording as a mic user.
- No retention limit or cleanup for the audio history yet.
- Meeting detection only runs in `probe`. The daemon does not record meetings yet.
- The short-press hint goes to stderr. The 🤫 overlay that shows it next to the indicator for
  about 2 s comes in a follow-up PR.
- Another key while fn is held cancels at any point of the hold. The Mac cancels only in the
  first second (`chordWindow`).
