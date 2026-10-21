# shepetal for Windows

Hold Ctrl+Win, talk, and the text lands at the cursor. Double-tap Ctrl+Win (or press Ctrl+Win+Space) for hands-free, then tap Ctrl+Win to stop. Speech-to-text runs on the PC with whisper.cpp, and nothing you say leaves it.

Windows keyboards don't report fn, so the hotkey is Ctrl+Win, the default of Wispr Flow's Windows app (docs/re/dictation-input.md, section 1).

## Architecture

One Cargo workspace (`windows/Cargo.toml`, `members = ["crates/*"]`), one crate per job:

| Crate | Package | What it does |
|---|---|---|
| `crates/core` | `shepetal-core` | Pure rules: the Ctrl+Win gesture (hold, double tap, Ctrl+Win+Space, Esc, chords), text cleanup, the focus rule, retention, model tiers |
| `crates/input` | `input` | The low-level keyboard hook, the 🤫 overlay (bottom-left, click-through, topmost) and the tray icon, on one thread with its own message loop |
| `crates/audio` | `audio` | Mic capture at 16 kHz mono with a pre-roll, the kept-audio store (owner-only folder), the model download (SHA-256 checked) and whisper.cpp |
| `crates/insert` | `insert` | Pastes into the window that stayed in front, or leaves the text on the clipboard with a Ctrl+V hint (goal rule 8) |
| `crates/meetings` | `meetings` | Detects calls by who holds the mic, offers to record them, and after the click records Me.wav and Others.wav |
| `crates/app` | `app`, binary `shepetal.exe` | Wires the five together; single instance, start at login, onboarding, the meeting card |

`shepetal.exe` is a GUI-subsystem exe, so Windows opens no console window for it (CI checks the PE header). Its threads:

```
input thread (hook, 🤫, tray) --Event--> forwarder --+
meetings::watch (polls every 1 s) --Notice---------+--> main thread: core Gesture -> app Flow
STT thread (model fetch + load, whisper) --Text----+        |  Mic.start/stop, Store.save, insert,
        ^                                                    |  Ui.set_mode/show_hint
        +-------------- samples after each Stop -------------+
```

`crates/app/src/flow.rs` is one dictation, from the gesture's action to the text at the cursor:
- Start: remember the foreground window first, then start the mic. The 🤫 turns red (orange for hands-free).
- Stop: keep the clip, turn the 🤫 blue, and send the samples to the STT thread. The text goes through `flow::rules` (`shepetal_core::text::cleanup`, then spoken dates become `DD.MM.YY`, docs/text-rules.md), then `insert::insert`, which pastes only into the window remembered at Start. Otherwise the text stays on the clipboard and the hint says why and to press Ctrl+V.
- Too short: the clip is kept as `<stamp>.tooshort.wav`, nothing is transcribed, and "Hold Ctrl+Win to talk · double-tap for hands-free" shows for 2 s. A cancel (Esc, or Ctrl+Win used as a shortcut such as Ctrl+Win+D) is kept as `<stamp>.cancelled.wav`.
- A press while the last clip is still transcribing is ignored. If saving the clip fails, the text is still inserted and the error shows after.

`flow.rs` talks to the mic, store, insert and overlay through four small traits, so its tests run with fakes on any OS. `win.rs` implements them with the real crates.

**Meetings.** A meeting is never recorded on its own. When `meetings::watch` reports one, a small card shows just above the 🤫: "Meeting detected · Zoom", Record and Not now (as on the Mac). Record starts the recording and the hint says so; Not now hides the card; the card goes away by itself if the call ends first. The card never takes focus, so clicking it leaves the call in front. `meeting.rs` (pure, tested) decides what each meetings event shows and where the card sits; `dialog.rs` draws it.

**No sounds.** Shepetal plays no sound. The system message box plays its icon's sound, so the questions at start use `dialog.rs`'s own silent dialog (standard buttons, so Tab, Enter and Esc work).

**Data.** Everything lives in `%LOCALAPPDATA%\Shepetal`: `audio\` holds every dictation clip, `meetings\<time>\` the meeting recordings, `models\` the speech model. The install itself is in `%LOCALAPPDATA%\Programs\Shepetal`.

**Onboarding.** Every start checks Windows' three microphone switches (Microphone access, Let apps access your microphone, Let desktop apps access your microphone). If any is off, Shepetal offers to open Settings > Privacy & security > Microphone. If the speech model is missing, it asks before it downloads it (base.en q5_1, 60 MB; large-v3-turbo q5_0, 574 MB, on an NVIDIA build). That download is the only network access. If you decline, Shepetal closes and asks again at the next start.

**Single instance.** A named mutex, `Shepetal.SingleInstance`. A second start says Shepetal is already running and exits. The installer's `AppMutex` uses the same name, so setup and the uninstaller ask you to quit a running Shepetal first.

**Start at login.** The `Shepetal` value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. The installer's "Start Shepetal when I sign in" task (on by default) writes it, the tray's Start at login item toggles it, and the uninstaller removes it.

## Build

On Windows 10 or 11 with Rust (MSVC toolchain), Visual Studio 2022 Build Tools with the C++ workload, CMake and LLVM (whisper-rs builds whisper.cpp and runs bindgen), and Inno Setup 6:

```powershell
cd windows
cargo build --release          # target\release\shepetal.exe
cargo test --release
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" /DAppVersion=0.1.0 installer\shepetal.iss
installer\test-install.ps1 target\installer\shepetal-setup-0.1.0.exe   # silent install, checks, uninstall
```

`test-install.ps1` removes an existing per-user Shepetal install. It checks the exe in `%LOCALAPPDATA%\Programs\Shepetal`, the Start menu entry and the Run value. After the uninstall, it checks that these are gone, that the models were deleted and that a recording was kept.

CI (`.github/workflows/windows.yml`, job `windows`, on windows-latest) runs all of the above and uploads `shepetal-setup-<version>.exe` as the `shepetal-windows-setup` artifact.

The pure crates also test on Linux or macOS (`app` takes only `core` and the pure half of `input` off Windows). CI runs this as the `windows-pure-on-linux` job:

```sh
cd windows
cargo test -p app -p shepetal-core -p input -p insert -p meetings
# or, without a Rust toolchain, from the repo root:
docker run --rm -v "$PWD/windows":/src -w /src -e CARGO_TARGET_DIR=/tmp/target rust:1-slim \
  cargo test -p app -p shepetal-core -p input -p insert -p meetings
```

## Installer

`installer/shepetal.iss` (Inno Setup 6) installs per user, without admin rights:
- `shepetal.exe` goes to `%LOCALAPPDATA%\Programs\Shepetal`, and Shepetal appears in the Start menu and in Settings > Apps.
- Start at login is a task, on by default.
- The uninstaller removes the exe, the Start menu entry, the Run value and `%LOCALAPPDATA%\Shepetal\models`. It keeps your recordings (`audio\` and `meetings\`).

The exe and the installer are not code-signed, so SmartScreen warns on first run ("More info" > "Run anyway").

## Hand test on a Windows 11 PC

These need a real keyboard, a voice and a mic, so CI can't run them. Use a Windows 11 PC with a mic and Notepad. Download `shepetal-windows-setup` from the CI run's artifacts and unzip it.

1. **Install.** Run `shepetal-setup-<version>.exe`. Expected: no UAC prompt. The wizard installs to `%LOCALAPPDATA%\Programs\Shepetal` with "Start Shepetal when I sign in" checked, and finishes with "Start Shepetal now".
2. **Mic privacy.** Before starting Shepetal, turn off Settings > Privacy & security > Microphone > "Let desktop apps access your microphone". Start Shepetal. Expected: a dialog, with no sound, says Windows keeps desktop apps away from the mic. Yes (or Enter) opens that Settings page; Esc closes the dialog. Turn the switch back on.
3. **Model.** On first start, Shepetal asks to download the speech model, with its size. Click Yes. Expected: within a minute or two (60 MB) the model is in `%LOCALAPPDATA%\Shepetal\models`. Click No instead on another run: Shepetal says it is closing and asks again at the next start.
4. **🤫.** Expected: a small 🤫 (about 18 px at 100 % scaling) 8 px from the bottom-left corner of the main display, above the taskbar. It stays on top of a full-screen browser and on every virtual desktop. Clicking it reaches the window under it. The tray has the Shepetal icon with Open, Pause, Start at login, Donate (Buy Me a Coffee, GitHub Sponsors) and Quit.
5. **Hold to talk.** In Notepad, hold Ctrl+Win, say "Testing one two three, this is a hold to talk check.", and release. Expected: a red ring while you hold, blue after release, then the text appears at the cursor. The Start menu does not open. What you had on the clipboard before is back.
6. **Hands-free.** Tap Ctrl+Win twice quickly. Expected: orange ring, and it stays orange after release. Say two sentences, then tap Ctrl+Win once: the text appears. Then, with two keyboard layouts installed, hold Ctrl+Win and press Space. Expected: the ring turns orange too, and the keyboard layout does not change. With Shepetal paused, Ctrl+Win+Space switches the layout as usual.
7. **Short press.** Tap Ctrl+Win once and wait. Expected: nothing is inserted, and "Hold Ctrl+Win to talk · double-tap for hands-free" shows next to the 🤫 for about 2 s. A new `<stamp>.tooshort.wav` is in `%LOCALAPPDATA%\Shepetal\audio`.
8. **Cancel.** Hold Ctrl+Win, speak, and press Esc. Then hold Ctrl+Win and press D (a new virtual desktop opens). Expected: nothing is inserted either time, and each leaves a `<stamp>.cancelled.wav`.
9. **Focus moved (rule 8).** Hold Ctrl+Win in Notepad, start talking, click into another window, and release. Expected: nothing is typed anywhere. Focus is not moved back. The hint says the window changed and to press Ctrl+V, and Ctrl+V pastes the text.
10. **Elevated window.** Open Notepad with "Run as administrator" and dictate into it. Expected: the text is left on the clipboard, and the hint says the window runs as administrator.
11. **Recordings.** Tray > Open. Expected: Explorer opens `%LOCALAPPDATA%\Shepetal`. `audio\` has one WAV per dictation from the steps above, cancelled and too short ones included. Each plays as the clip you spoke.
12. **Start at login.** Tray > Start at login: the check mark goes away, and the `Shepetal` value is gone from `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (regedit). Click it again: the check is back. Sign out and in: Shepetal starts.
13. **Single instance.** Start Shepetal again from the Start menu. Expected: a dialog says it is already running, with no sound, and there is still one tray icon.
14. **Pause.** Tray > Pause, then hold Ctrl+Win and speak. Expected: nothing happens. Unpause, and dictation works again.
15. **Meeting.** Join a Zoom, Teams or Google Meet call (in Chrome or Edge, in front). Expected: about 5 s after joining, a card above the 🤫 says "Meeting detected · <app>" with Record and Not now, and nothing is recorded yet (no new folder in `%LOCALAPPDATA%\Shepetal\meetings`). Click Record: the call window keeps the focus (its title bar stays active), the card goes away and the hint says "Recording the meeting". Talk for a minute, then leave. Expected: the hint says where the meeting was saved, and that folder has Me.wav (your mic) and Others.wav (the call audio). Join again and click Not now: the card goes away and nothing is recorded. Join once more and leave without clicking: the card goes away by itself.
16. **Quit and uninstall.** Tray > Quit: the 🤫 and the tray icon go away. Uninstall from Settings > Apps. Expected: no UAC prompt. `%LOCALAPPDATA%\Programs\Shepetal`, the Start menu entry, the Run value and `%LOCALAPPDATA%\Shepetal\models` are gone, and `%LOCALAPPDATA%\Shepetal\audio` and `meetings` are still there.

## Known limits

- **No fn key.** Windows keyboards don't report fn to apps, so the default hotkey is Ctrl+Win. `input::Hotkey::parse` takes others, but there is no setting for it yet.
- **Ctrl+Win+Space.** The hook swallows Space only while the hotkey is held and the 🤫 shows Recording or Hands-free, so the hands-free chord doesn't also switch the keyboard layout. While Shepetal is idle or paused, Windows' own Ctrl+Win+Space (switch layout) works as usual. Every other key passes through.
- **No history window and no retention setting.** Clips are kept (the "keep" default). The 24 h retention in `audio::Store::prune` and the history search, replay and re-transcribe are not wired to any UI yet. Tray > Open shows the folder.
- **Model tiers.** `shepetal-core::model` picks sherpa-onnx Parakeet tiers, but `audio` runs whisper.cpp only, so the app uses `audio::model::choose` (base.en q5_1 on the CPU, large-v3-turbo with the `cuda` feature). `base.en` is English only. None of this is measured on a Windows PC yet.
- **The mic shows as in use while Shepetal runs.** `audio::Mic` keeps the default mic open for its pre-roll, so the taskbar mic icon stays on. A change of the default mic needs a restart.
- **Task Manager's startup switch.** If you disable Shepetal under Task Manager > Startup apps, Windows records that separately (`StartupApproved`), and the tray's check mark does not show it.
- **Text around the cursor is not read**, so `shepetal_core::text::fit` (spacing and casing against the text before the cursor) is not applied. Only the cleanup runs.
- **The meeting card is mouse only.** It never takes focus, so the keyboard and screen readers can't reach it.
- **Quitting during a meeting** cuts its recording at that point. The WAV headers are rewritten after every batch, so both files stay playable up to there.
- Single instance is per Windows session: two users who are signed in at once each get their own Shepetal.
