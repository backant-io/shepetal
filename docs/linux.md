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
| Gesture | Recording starts on the fn press. Hold fn at least 500 ms for push-to-talk. Two taps with at most 500 ms between the release and the second press for hands-free, next press stops. A shorter press with no second tap is too short: nothing is transcribed or typed, the clip is kept as too short, and the hint `Hold fn to talk · double-tap for hands-free` shows next to 🤫 for about 3 s (and goes to stderr). A chord (fn+F1) cancels without a hint, and the clip is kept as cancelled. The 500/500 ms values match the Mac (`Sources/ShepetalCore/FnGesture.swift`) and the 500 ms debounce in `docs/re/dictation-input.md` section 2.3. Set another key with `SHEPETAL_KEY` (`rightalt`, `rightmeta`, `capslock`, `f13`, `rightctrl` or an evdev code). | Config file, tunable thresholds |
| Mic | `pw-record` at 16 kHz mono s16, falling back to `parecord` (PulseAudio). Stopped with SIGINT so the WAV header is written. | `pipewire-rs` stream, no temp file |
| STT | `sherpa-onnx-offline` (Parakeet) or `whisper-cli` from whisper.cpp (Whisper), run on the kept WAV. sherpa-onnx prints one JSON line per file on stdout, and shepetal reads its `text`. | `sherpa-rs` / `whisper-rs` in-process, model kept warm, sherpa-onnx streaming for meetings |
| Model | The Linux rows of the tier table in `docs/models.md` (goal rule 5). CPU: Parakeet TDT 0.6B v3 int8 on sherpa-onnx, or Parakeet TDT-CTC 110M int8 below 4 GB RAM. CUDA (`/dev/nvidia0`, 8 GB RAM or more): Parakeet TDT 0.6B v3 with `--provider=cuda`. Vulkan (an ICD in `/usr/share/vulkan/icd.d`, 8 GB RAM or more): Whisper large-v3-turbo q5_0 on whisper.cpp. | Thresholds from measured latency, VRAM check, the Whisper fallback for languages Parakeet lacks |
| Insert | See the matrix below | RemoteDesktop portal (`persist_mode=2`) on GNOME and KDE, clipboard plus paste key with restore for long text |
| Meeting | Parse `pw-dump`: running `Stream/Input/Audio` nodes that do not capture a sink monitor, matched to Zoom, Teams, Slack, Discord, Chrome/Chromium, Firefox. System audio is `<default.audio.sink>.monitor` from the `default` metadata. | Live `pw-dump --monitor`, record the monitor next to the mic |

`shepetal probe` prints all of this for the current machine. `shepetal daemon` runs the loop.

## 🤫 indicator

The same indicator as on the Mac (README, "Mac"): 🤫 about 18 px (at scale 1; GDK applies the
monitor scale), 8 px in from the bottom-left corner of the primary monitor. It is there the whole
time the daemon runs, idle included, stays on top of every window and workspace, never takes focus,
and lets every click through to the window below. The ring shows the state:

| Daemon line | 🤫 shows |
| --- | --- |
| `idle` | 🤫 alone |
| `recording` | red ring |
| `handsfree` | orange ring (after a double tap) |
| `processing` | blue ring, 🤫 and ring pulsing between full and 35% opacity, 0.6 s each way |
| `error <text>` | yellow ring, and the text next to 🤫 for about 4 s (`Transcription failed`, `Could not type or copy the text`; details go to stderr) |
| `hint <text>` | the text next to 🤫 for about 3 s, in white on a dark box; the ring stays. The short-press hint is `Hold fn to talk · double-tap for hands-free` (with the key's name when `SHEPETAL_KEY` is set) |

The colors are Apple's system red, orange, blue and yellow, which the Mac indicator uses.

### Backends

| Session | How 🤫 is drawn |
| --- | --- |
| X11 (any desktop) | `linux/indicator/shepetal-indicator`: an override-redirect window. The window manager never manages it, so it is on every workspace, has no frame and never gets focus. Its input shape is empty, so clicks go through. It re-raises itself every second (`XRaiseWindow`), so a window mapped later covers it for at most a second. Without a compositor the window is shaped to the pixels it draws. |
| Wayland with wlr-layer-shell (KDE Plasma, Sway, Hyprland, other wlroots compositors) | The same program: a layer surface on the `overlay` layer (above full-screen windows), anchored bottom and left with 8 px margins, keyboard interactivity `none`, exclusive zone -1 (the screen corner, over panels, as the Mac's sits over the Dock), and an empty input region. |
| GNOME Wayland | `linux/gnome-extension/`, a GNOME Shell extension (GNOME 45 and later), because Mutter has no layer-shell and lets no app place an overlay. It adds 🤫 as top chrome (above all windows, also full-screen ones), not part of the input region and not reactive, so clicks go through. |

`shepetal daemon` starts `shepetal-indicator` from PATH, except on GNOME Wayland, where it says
that 🤫 comes from the extension. If the program is missing, the daemon says so once on stderr.
Whenever the indicator exits while the daemon runs (a crash, an X server or compositor restart, a
display that was not ready yet), the daemon reports it on stderr, reaps it and starts it again
after 2 s, doubling the wait up to 64 s while it keeps exiting within 30 s (goal rule 3: 🤫 is
always there). If the socket cannot be made (other than another daemon holding it), the daemon
says why and goes on without 🤫. Either way dictation works, and hints still go to stderr. On a Wayland compositor without layer-shell (and not GNOME) the indicator exits with a
message; `GDK_BACKEND=x11` runs it on XWayland as an X11 window.

### Toolkit: GTK 3 with gtk-layer-shell, from Python (PyGObject)

- **GTK 3, not GTK 4.** GTK 4 dropped popup (override-redirect) windows, keep-above and sticky
  from its API, so its X11 path would need raw Xlib calls. GTK 3 has popup windows and
  `gtk_widget_input_shape_combine_region` (an empty XShape input region on X11, an empty
  `wl_surface` input region on Wayland), and gtk-layer-shell (GTK 3) turns the same window into a
  layer surface. The drawing code is shared by both.
- **Python, not Rust bindings.** The indicator is one file of about 250 lines with no build step.
  The gtk-rs project no longer maintains its GTK 3 bindings (gtk3-rs is archived), and they would
  add dozens of crates to a daemon that has one dependency (`serde_json`).
- **A separate process.** The daemon stays one small binary that also runs without a desktop
  session, and a crash in the GUI cannot stop dictation.
- **Dependencies** (Debian and Ubuntu names): `python3-gi`, `python3-gi-cairo`, `gir1.2-gtk-3.0`,
  `fonts-noto-color-emoji`, and on Wayland `gir1.2-gtklayershell-0.1` (gtk-layer-shell 0.6 or
  later).
- The GNOME extension is plain GJS with St and Gio from GNOME Shell. It needs nothing else.

### Daemon to indicator: a Unix socket

- `$XDG_RUNTIME_DIR/shepetal.sock`, mode 0600. The daemon refuses a runtime dir that is not
  absolute or that group or others can enter (the XDG Base Directory spec requires 0700).
  Without one it runs with no 🤫.
- The daemon listens; indicators connect. Each line is one of the daemon lines in the table above,
  UTF-8, ending in `\n`. Newlines inside a text are turned into spaces, so a text cannot start a
  line of its own. Readers ignore lines they do not know.
- A reader that connects gets the current state at once (a hint, or an error's text, is not
  replayed). A reader that stops reading is dropped after a 100 ms write timeout, so it cannot
  stall dictation.
- A socket that answers belongs to a running daemon, and a second `shepetal daemon` exits with
  `another shepetal daemon is running`: two daemons would both record on every fn press. A socket
  left by a daemon that died is replaced.
- `shepetal-indicator` exits when the daemon closes the socket, which the kernel also does when
  the daemon is killed (SIGKILL included), so 🤫 never outlives the daemon. The GNOME extension
  hides 🤫 instead and tries to connect again every 2 s. Without an absolute `XDG_RUNTIME_DIR`,
  `shepetal-indicator` exits with a message instead of looking for the socket elsewhere.
- `shepetal indicator` opens the socket and starts the indicator like the daemon does, without the
  hotkey, and sends each line it reads on stdin. The Docker check and the manual steps below use it.

Code: `linux/src/indicator.rs` (the socket), `linux/src/main.rs` (`start_indicator`, and `act` and
`listen`, which send the states), `linux/indicator/shepetal-indicator`, `linux/gnome-extension/`.

### Checks (Docker)

`linux/indicator/check.sh [OUT_DIR]`, from the repo root, builds an ubuntu:24.04 image with cargo,
GTK 3, gtk-layer-shell, Xvfb, Sway and grim, and runs:

1. `cargo test`. Among the tests: the socket is 0600 in a private runtime dir and refused in a
   shared one; a late reader gets the current state; text cannot inject a line; a second daemon is
   refused and a dead one's socket replaced; a hands-free dictation through the real `listen` loop
   sends `recording`, `handsfree`, `processing`, `idle`; a too-short press sends `idle` and the
   hint; failed typing and failed speech-to-text send their `error` lines.
2. `python3 linux/indicator/test_indicator.py`: the position (bottom-left of the primary monitor,
   also when it is right of or below another), the width with and without text, the ring per
   state, the parsing of every daemon line, and the pulse curve.
3. X11: Xvfb at 1280x720 with no window manager and no compositor. `shepetal indicator` starts 🤫;
   `xwininfo` must show an override-redirect 18x18 window at 8,694. A full-screen window mapped
   after it must not hide it once a second has passed, and an `xdotool` click on 🤫 must reach
   that window below it (the empty input shape). Then for each daemon line a
   screenshot (ImageMagick `import`) is checked pixel by pixel: 🤫's yellow face inside the 18 px
   square 8 px in from the bottom-left corner, the ring's color at its edge, the white-on-dark
   text box only while a hint or error shows, its removal after about 3 s (hint) and 4 s (error),
   the blue ring's opacity changing across three shots while processing, and nothing drawn
   anywhere else. Last, closing the socket must end `shepetal-indicator`.
4. Wayland: headless Sway (`WLR_BACKENDS=headless`) at 1280x720 with a full-screen window open.
   The indicator's `WAYLAND_DEBUG` log must show `get_layer_surface` on layer 3 (overlay) with
   namespace `shepetal`, `set_anchor(6)` (bottom and left), `set_margin(0, 0, 8, 8)`,
   `set_keyboard_interactivity(0)`, `set_exclusive_zone(-1)`, and a last `set_input_region` with
   an empty region. The same screenshot checks run on `grim` shots, and the same exit check.
5. GNOME extension: eslint 9 with its recommended rules (which include parse errors) on
   `extension.js`, with no warnings allowed, in `node:22.11.0-slim`, and a check that
   `metadata.json` parses and has `uuid`, `name`, `description` and `shell-version`. And a
   lifecycle run under gjs (`linux/indicator/gnome-test/`): the real `extension.js` with St,
   Clutter, Main and Extension replaced by stand-ins (an actor used after `destroy()` throws) and a
   real socket. It checks placement, click-through, the ring and the hint, `disable()` while
   connected and while connecting, a quick `disable(); enable()`, and 🤫 hiding when the daemon
   stops and coming back when it starts again. Any `JS ERROR` on stderr fails the check.
6. X11 restart: the indicator is killed; the daemon must report it, reap it (no zombie) and bring
   🤫 back.

Screenshots and the indicator's stderr (with the Wayland protocol log) go to OUT_DIR (default: a
new temporary dir, printed at the end). What only a real desktop shows is in the manual steps below (I-1 to I-6).

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

## Text goes only into the window that kept focus (goal rule 8)

When a dictation starts, the daemon reads which window has focus, and reads it again when the
text is ready (`linux/src/focus.rs`):

| Session | How focus is read |
| --- | --- |
| X11 (any desktop; also a `startx` session, which reports `tty`, when `DISPLAY` is set) | `xdotool getactivewindow` (EWMH `_NET_ACTIVE_WINDOW`) |
| Sway (`SWAYSOCK` set or `XDG_CURRENT_DESKTOP` has `sway`) | `swaymsg -t get_tree`, the node with `"focused": true` |
| Hyprland (`HYPRLAND_INSTANCE_SIGNATURE` set) | `hyprctl activewindow -j`, its `address` |
| GNOME and KDE on Wayland | not readable by an app: the text is typed |

- Same window at both ends: the text is typed. The clipboard is not touched.
- Another window has focus: nothing is typed. The text goes to the clipboard (`wl-copy` on
  Wayland, else `xclip` or `xsel`), and the hint next to 🤫 says
  `Focus moved. The text is on the clipboard: press Ctrl+V (Ctrl+Shift+V in a terminal).`
- Focus unreadable at either end: there is nothing to compare, so the text is typed.
- Typing fails (the tool exits non-zero): the text goes to the clipboard with the hint
  `Typing failed. ...`. With only a clipboard tool installed the hint is `No typing tool. ...`.
- If the clipboard copy fails too, 🤫 turns yellow with `Could not type or copy the text`. The
  text is then not on the clipboard; it stays in the history line, where
  `shepetal history copy ID` gets it.
- Each focus read is cut off after 500 ms, so a hung `xdotool`, `swaymsg` or `hyprctl` cannot hold
  up the fn press; a read that is cut off counts as unreadable.
- On a desktop where focus cannot be read, `shepetal daemon` says so at start.
- shepetal never moves focus back to the first window, and the old clipboard is not restored
  when the text is left there (the user has not pasted it yet).

Typing tools give no "landed" signal on Linux (unlike the Mac's paste check), so a typed text
that the window ignores is not caught. The audio is kept either way.

## History, retention and paste last

Every recording gets one line in `$XDG_DATA_HOME/shepetal/history.jsonl` (0600;
`linux/src/history.rs`): its id (the unix ms it started, also the audio file's stem), the
outcome, the kept WAV's path, its length, the model that ran and the text. The outcomes are the
Mac's: `inserted`, `paste_failed` (not typed: left on the clipboard (rule 8), or neither typing nor
the clipboard worked; the text is in the line either way), `too_short`, `cancelled`, `no_speech`
(the model heard no words: nothing is typed) and `failed` (speech-to-text failed). A symlink or a
file that others can read in place of the history is refused. The file is only appended to, so
the daemon and the commands below never lose each other's lines; a re-transcription appends a new
line for the same id, and the last one wins.

| Command | Does |
| --- | --- |
| `shepetal history [WORDS...]` | lists entries, newest first, whose text has every word (any case) |
| `shepetal history play ID` | plays the kept audio with `pw-play` (or `paplay`) |
| `shepetal history copy ID` | puts the entry's text on the clipboard |
| `shepetal history retranscribe ID` | runs the standard engine (the model the tier table picks, or `SHEPETAL_MODEL`) on the kept audio, prints the text and stores it in the entry with the model that ran |
| `shepetal history retranscribe ID alternative` | the same with the alternative engine: the tier's fallback in docs/models.md (Parakeet 110M on CPU, Whisper turbo on CUDA, Parakeet v3 on CPU for Vulkan), from its own dir or file in `~/.local/share/shepetal/`. Refused while `SHEPETAL_MODEL` is set, since that names one model only |

As on the Mac, nothing here shows a model name: the commands say "standard" and "alternative",
and the name only goes into the history line and the daemon's stderr.

Paste last and copy last (F21) are the daemon's Shift+Alt+Z and Shift+Alt+X keys
(docs/linux-shortcuts.md). They take the newest history line with text, so they still work after
a restart. When typing fails, paste last leaves the text on the clipboard with the
`Typing failed. ...` hint, as a dictation does.

Retention (goal rule 4) is `keep`, the default, or `delete_after_24h`, set in
`$XDG_CONFIG_HOME/shepetal/config.json` as `{"retention": "delete_after_24h"}`. With 24 h the
daemon deletes, at start and then every minute, the audio of each recording that started 24 h ago
or earlier: the file of any outcome, also one without a history line. As on the Mac, only the
audio goes; the history line and its text stay, and `play` and `retranscribe` then say the audio
is gone. A missing, broken or unknown setting keeps everything. There is no "never store" setting.

## Security

- Dictated text goes to `wtype -`, `xdotool type --file -`, `ydotool type --file -`, `wl-copy`,
  `xclip` and `xsel` over stdin. It never goes in argv, which every local user can read with `ps`.
- Every dictation's raw audio is kept, the exact 16 kHz mono WAV the model received, in
  `$XDG_DATA_HOME/shepetal/audio/` (default `~/.local/share/shepetal/audio/`; an empty or relative
  `XDG_DATA_HOME` is ignored, as the XDG spec says). The directory is created 0700. If it is a
  symlink or open to other users, the recording is refused at the fn press and the daemon exits
  with the reason. Each
  file is a new `<unix-ms>.wav`, created with `O_CREAT|O_EXCL` (which also refuses a symlink) and
  mode 0600. Nothing is deleted unless the 24 h retention is on. A cancelled recording is renamed `<unix-ms>.cancelled.wav`, and
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
11. **Rule 8, X11 and Sway or Hyprland**: open gedit and a terminal. In gedit, double-tap fn,
    say a sentence, click into the terminal, then press fn once. Nothing is typed in either
    window, focus stays on the terminal, and next to 🤫 shows `Focus moved. The text is on the
    clipboard: press Ctrl+V (Ctrl+Shift+V in a terminal).` Ctrl+Shift+V pastes the sentence.
    Repeat without switching windows: the sentence is typed into gedit and the clipboard keeps
    what it held before.
12. **Rule 8, GNOME or KDE Wayland**: the same steps type the sentence into whatever window has
    focus at the end, since these desktops do not tell an app which window has focus.
13. **History**: after steps 6 to 8, `shepetal history` lists the dictations newest first with
    `inserted`, `too_short` and `cancelled`. `shepetal history play ID` plays the first one
    through the speakers. `shepetal history hello` lists only the entries with "hello".
14. **Paste last after a restart**: dictate into gedit, stop the daemon with Ctrl+C and start it
    again, click into another text field and press Shift+Alt+Z: the same text is typed there once
    the keys are up. `shepetal history retranscribe ID alternative` prints the text from the
    other engine (its model must be in `~/.local/share/shepetal/` too, as in step 2; on CPU
    `sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8` from the same asr-models release).
15. **24 h retention**: write `{"retention": "delete_after_24h"}` to
    `~/.config/shepetal/config.json` and start the daemon with a recording from
    more than 24 h ago in `~/.local/share/shepetal/audio/`: it prints
    `retention: deleted N recordings older than 24 h`, and the file is gone. `shepetal history`
    still lists its text, and `shepetal history play ID` says the audio is gone.

### Manual test steps: 🤫 indicator

Setup on each desktop: steps 1 to 3 of the steps above, plus
`sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-gtklayershell-0.1 fonts-noto-color-emoji`
and `mkdir -p ~/.local/bin && ln -s "$PWD/linux/indicator/shepetal-indicator" ~/.local/bin/`
(`~/.local/bin` must be on PATH).

1. **I-1, X11** ("Ubuntu on Xorg", Xfce or i3): run `shepetal daemon`. A small 🤫 sits about
   8 px in from the bottom-left corner of the primary monitor (the one `xrandr` marks `primary`),
   over the panel if one is there. Switch workspaces: it stays. Play a video full screen in
   Firefox: it stays on top. Click on 🤫: the click reaches what is below, and the focused
   window does not change. Hold fn and talk: red ring. Release: blue pulsing ring, then 🤫 alone
   when the text is typed. Double-tap fn: orange ring until the next press. Tap fn once:
   `Hold fn to talk · double-tap for hands-free` shows to the right of 🤫 for about 3 s.
2. **I-2, KDE Plasma Wayland**: the same as I-1. 🤫 sits over the bottom panel, and a click on
   it reaches the panel button below it.
3. **I-3, Sway or Hyprland**: the same as I-1, with a full-screen window (`fullscreen` in Sway,
   `fullscreen` dispatcher in Hyprland) open.
4. **I-4, GNOME Wayland**: `cp -r linux/gnome-extension ~/.local/share/gnome-shell/extensions/shepetal-indicator@backant.io`,
   log out and back in, then `gnome-extensions enable shepetal-indicator@backant.io`. Start
   `shepetal daemon`: it prints that 🤫 comes from the extension, and 🤫 appears within 2 s. Run
   the checks of I-1, also over a full-screen video and in the Activities overview. Stop the
   daemon (Ctrl+C): 🤫 disappears. Start it again: 🤫 is back within about 2 s. Turn the
   extension off with `gnome-extensions disable`: 🤫 disappears, and
   `journalctl --user -b | grep -i shepetal` shows no errors from the extension.
5. **I-5, two monitors and HiDPI**: with a second monitor left of the primary, 🤫 is on the
   primary. Make the other one primary (Settings > Displays): 🤫 moves there. At 200% scale,
   🤫 is about 36 physical pixels, 16 from the corner.
6. **I-6, without the hotkey**: on any of the desktops, `printf 'recording\nhint Hello from shepetal\n' | (cat; sleep 5) | shepetal indicator`
   shows a red ring and the text for about 3 s, then 🤫 disappears when the command ends.

## Known gaps

- Transcription runs on the input thread, so keys pressed during it queue up. Each event is
  stamped when the loop takes it, so a hold made during a transcription comes out as too short,
  and its speech is not recorded at all (#59).
- If every keyboard closes (a Bluetooth keyboard sleeps), the daemon stops a running recorder
  with SIGINT, keeps the clip as `*.cancelled.wav` and exits. A daemon killed by a signal
  (`kill`, SIGKILL) still leaves a running `pw-record` behind (#45).
- Vulkan counts as present when `/usr/share/vulkan/icd.d` has any file, which includes Mesa's
  software renderer (lavapipe). Such a machine gets Whisper turbo on Vulkan, not Parakeet on CPU (#46).
- Parakeet TDT-CTC 110M is English only. The 4 GB RAM line that picks it stands in for the
  table's "low-end ARM" and is not measured (#46).
- The speech-to-text runner starts per dictation, so the model loads every time. Text-ready time
  on a real Linux machine is not measured (#46).
- No hotplug: keyboards plugged in after start are not seen.
- Only ydotoold's virtual device is skipped. Any other uinput device that declares fn still
  counts as an fn keyboard, so with one running and fn invisible the daemon starts and fn does
  nothing. Skipping every virtual device would also drop a remapper's (keyd) virtual keyboard,
  which is then the only device that sends real keys.
- Only keyboards that report the hotkey are read, so a key pressed on another keyboard while fn
  is held does not cancel.
- Whether `pw-record -P '{ application.name = shepetal }'` really renames the stream is not
  verified. If it does not, `probe` lists shepetal's own recording as a mic user.
- Meeting detection only runs in `probe`. The daemon does not record meetings yet.
- 🤫 on X11 re-raises itself once a second, so a window mapped above it (or an override-redirect
  menu) can cover it for up to a second. Watching the root window's restacking would close that.
- On Wayland, wlr-layer-shell has no notion of a primary output. 🤫 goes to the monitor GTK
  reports as primary, or else its first monitor, which is not always the one KDE calls primary.
- The GNOME extension has passed eslint and the gjs lifecycle run with stand-ins for the Shell
  modules, but has not run in a real GNOME Shell yet (I-4), and `shell-version` lists 45 to 51
  without a run on any of them. It does not move 🤫 when only the scale factor changes, and on
  GNOME on Xorg it would show a second 🤫 next to `shepetal-indicator` if both are on.
- Two daemons started at the same instant could both pass the "another daemon" check before
  either binds the socket.
- 🤫 needs a color emoji font (`fonts-noto-color-emoji`). Without one it draws whatever glyph
  fontconfig falls back to.
- Another key while fn is held cancels at any point of the hold. The Mac cancels only in the
  first second (`chordWindow`).
