# shepetal on Linux

Status: v0 scaffold. The pure logic is unit-tested in Docker. The device paths (hotkey, mic,
whisper, typing) are written but have not been run on a real desktop yet.

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
| Hotkey | Read `/dev/input/event*` directly. Every key event goes to one state machine. User must be in the `input` group. | `evdev` crate to filter real keyboards and survive hotplug |
| Gesture | Hold Right Ctrl at least 300 ms for push-to-talk. Two taps within 400 ms for hands-free, next press stops. A chord (Right Ctrl+C) cancels. Set the key with `SHEPETAL_KEY` (`rightctrl`, `rightalt`, `rightmeta`, `capslock`, `f13` or an evdev code). | Config file, tunable thresholds |
| Mic | `pw-record` at 16 kHz mono s16, falling back to `parecord` (PulseAudio). Stopped with SIGINT so the WAV header is written. | `pipewire-rs` stream, no temp file |
| STT | `whisper-cli` from whisper.cpp on a temp WAV | `whisper-rs` in-process, model kept warm, sherpa-onnx for streaming |
| Model | `large-v3-turbo` on CUDA (`/dev/nvidia0`) or Vulkan (an ICD in `/usr/share/vulkan/icd.d`) when RAM is at least 8 GB. On CPU: `small` (16 GB and 8 cores or more), `base` (8 GB or more), else `tiny`. | Thresholds from measured latency, VRAM check |
| Insert | See the matrix below | Clipboard paste with restore once a key injector exists |
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
`ydotool` needs `ydotoold` running and access to `/dev/uinput`.

The clipboard fallback does not restore the old clipboard. In that case nothing can send the
paste keystroke, so the user pastes by hand, and restoring the clipboard would delete the text first.

## Packaging

- **`.deb` / AppImage**: recommended. A plain process can read `/dev/input`, run `pw-record` and
  call `wtype`/`xdotool`/`ydotool`. The installer only has to add the user to the `input` group,
  and the `.deb` can depend on `pipewire-bin` and `wtype | xdotool`.
- **Flatpak**: a bad fit for v0. The sandbox has no `/dev/input` unless you set `--device=all`,
  which Flathub reviewers push back on. Host binaries (`wtype`, `xdotool`) need
  `flatpak-spawn --host`, and global hotkeys inside the sandbox would mean the GlobalShortcuts
  portal, which does not report key release, so there is no push-to-talk.
- **Snap**: same problems as Flatpak, but `classic` confinement would work.
- Never ship model weights in the package. They download on first run into `~/.local/share/shepetal/`.

## Build and test

See [linux/README.md](../linux/README.md). It is one `docker run` that runs `cargo test`,
builds the release binary and runs `probe` against the committed `pw-dump` fixture.

## Manual test steps (real Ubuntu 24.04 desktop)

Not yet done. These are the steps:

1. `sudo apt install pipewire-bin wl-clipboard xclip xdotool ydotool cmake build-essential`,
   then `sudo usermod -aG input $USER` and log out and back in.
2. Build whisper.cpp (`cmake -B build && cmake --build build -j`), put `build/bin/whisper-cli`
   on PATH, then download the model `shepetal probe` names
   (`./models/download-ggml-model.sh base`) into `~/.local/share/shepetal/ggml-base.bin`.
3. `cargo build --release && ./target/release/shepetal probe`. Check that RAM, cores, the GPU
   and the insertion backend match the machine. On GNOME Wayland it must say `Ydotool`.
4. Start a Zoom call or a Google Meet in Firefox and run `probe` again. It must list the app as
   a mic user with `meeting=Some(..)`. Close the call, and it must disappear.
5. `ydotoold &` (GNOME Wayland only), then `./target/release/shepetal daemon`.
6. Open gedit. Hold Right Ctrl, say "hello world", release: the text appears.
7. Tap Right Ctrl once: nothing is typed. Press Right Ctrl+C in a terminal: nothing is typed.
8. Double-tap Right Ctrl, talk for 20 seconds while typing elsewhere, then press Right Ctrl
   once: the whole passage is typed.
9. Repeat steps 6 to 8 in an X11 session ("Ubuntu on Xorg" at login), where it must use `xdotool`.
10. `SHEPETAL_KEY=rightalt ./target/release/shepetal daemon`: Right Alt now works and Right Ctrl does nothing.

## Known gaps

- Transcription runs on the input thread, so keys pressed during it queue up.
- No hotplug: keyboards plugged in after start are not seen.
- Whether `pw-record -P '{ application.name = shepetal }'` really renames the stream is not
  verified. If it does not, `probe` lists shepetal's own recording as a mic user.
- Meeting detection only runs in `probe`. The daemon does not record meetings yet.
