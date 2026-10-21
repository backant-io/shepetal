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
| `crates/meetings` | `meetings` | Treats any other app using the mic or the camera as a meeting, offers to record it, and after the click records Me.wav and Others.wav |
| `crates/app` | `app`, binary `shepetal.exe` | Wires the five together; single instance, start at login, onboarding, the meeting card, Google sign-in and the license |

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
- Stop: keep the clip, turn the 🤫 blue, and send the samples to the STT thread. The text goes through `shepetal_core::text::cleanup`, then `insert::insert`, which pastes only into the window remembered at Start. Otherwise the text stays on the clipboard and the hint says why and to press Ctrl+V.
- Too short: the clip is kept as `<stamp>.tooshort.wav`, nothing is transcribed, and "Hold Ctrl+Win to talk · double-tap for hands-free" shows for 3 s. A cancel (Esc, or Ctrl+Win used as a shortcut such as Ctrl+Win+D) is kept as `<stamp>.cancelled.wav`.
- A press while the last clip is still transcribing is ignored. If saving the clip fails, the text is still inserted and the error shows after.

`flow.rs` talks to the mic, store, insert and overlay through four small traits, so its tests run with fakes on any OS. `win.rs` implements them with the real crates.

**Meetings.** A meeting is never recorded on its own. When another app has used the mic or the camera for 5 s, `meetings::watch` reports it and a small card shows just above the 🤫: "Meeting detected · Zoom" (the app's exe or package name), Record and Not now (as on the Mac). Record starts the recording and the hint says so. Not now hides the card, and so does waiting 20 s or the mic and camera being released first; no new card comes until they are released and used again. The card never takes focus, so clicking it leaves the call in front. `meeting.rs` (pure, tested) decides what each meetings event shows and where the card sits; `dialog.rs` draws it.

**No sounds.** Shepetal plays no sound. The system message box plays its icon's sound, so the questions at start use `dialog.rs`'s own silent dialog (standard buttons, so Tab, Enter and Esc work).

**Data.** Everything lives in `%LOCALAPPDATA%\Shepetal`: `audio\` holds every dictation clip, `meetings\<time>\` the meeting recordings, `models\` the speech model. The install itself is in `%LOCALAPPDATA%\Programs\Shepetal`.

**Onboarding.** Every start checks Windows' three microphone switches (Microphone access, Let apps access your microphone, Let desktop apps access your microphone). If any is off, Shepetal offers to open Settings > Privacy & security > Microphone. If the speech model is missing, it asks before it downloads it (base.en q5_1, 60 MB; large-v3-turbo q5_0, 574 MB, on an NVIDIA build). Besides the account calls (see Account), that download is the only network access. If you decline, Shepetal closes and asks again at the next start.

**Account.** As on the Mac (#70): sign in once with Google for a free 30-day trial (no card). After the trial, Shepetal is $4.99 once for a lifetime license with future updates.
- Sign-in follows OAuth for native apps with PKCE (RFC 8252, RFC 7636) against the account service's `/app/login` and `POST /api/app/token` (web/API.md on feat/web). Shepetal opens the login page in your default browser with a loopback redirect, `http://127.0.0.1:<free port>/callback`. A listener bound to 127.0.0.1 only takes that one request, checks the `state`, and the browser tab says you can close it. The code and the verifier are then traded for the token.
- The token is kept in the Windows Credential Manager (a generic credential named `Shepetal/account`, which Windows encrypts with DPAPI for your user), never in a file. Sign out deletes it and revokes it on the service.
- The license is checked at launch and every 24 hours, in the background, never during a dictation: a check is not started while you dictate, and one in flight is cancelled when you press Ctrl+Win. The last answer is cached in `%LOCALAPPDATA%\Shepetal\account.json` (status, trial end, email; no token) and holds for 7 days offline. A failed check retries after an hour.
- The tray menu starts with the account: "Free trial: N days left · <email>" or "Yours forever", then Sign in with Google, Get Shepetal for $4.99 (Stripe Checkout in the browser, re-checked every minute for an hour after), Check license now, Sign out.
- The first start offers sign-in in a dialog, waits for the browser (the dialog closes itself), then says the days left or "Yours forever". When the trial has ended, the start offers Get Shepetal.
- When sign-in is required and you are not signed in, the trial has ended or the license could not be checked for 7 days, Ctrl+Win only shows a hint next to the 🤫 and records nothing.
- Sign-in is required only in a build with the `require-sign-in` feature (`cargo build --release --features require-sign-in`), the Mac's `ShepetalRequiresSignIn`. Until the account service is live, the default build offers sign-in but Ctrl+Win always dictates. `SHEPETAL_REQUIRE_SIGNIN=1` or `0` overrides the build for a hand test. `SHEPETAL_ACCOUNT_URL` points Shepetal at another account service (https, or http on localhost), and `SHEPETAL_CREDENTIAL_TARGET` at another credential name.
- `license.rs` (protocol, license policy, cache), `account.rs` (the state machine, with the clock and the token store injected) and `loopback.rs` are pure and tested on any OS. `winaccount.rs` has WinHTTP, the Credential Manager and the system random generator; its tests run on the windows-latest job. These calls, the model download and nothing else go online; audio and text never do.

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
7. **Short press.** Tap Ctrl+Win once and wait. Expected: nothing is inserted, and "Hold Ctrl+Win to talk · double-tap for hands-free" shows next to the 🤫 for about 3 s. A new `<stamp>.tooshort.wav` is in `%LOCALAPPDATA%\Shepetal\audio`.
8. **Cancel.** Hold Ctrl+Win, speak, and press Esc. Then hold Ctrl+Win and press D (a new virtual desktop opens). Expected: nothing is inserted either time, and each leaves a `<stamp>.cancelled.wav`.
9. **Focus moved (rule 8).** Hold Ctrl+Win in Notepad, start talking, click into another window, and release. Expected: nothing is typed anywhere. Focus is not moved back. The hint says the window changed and to press Ctrl+V, and Ctrl+V pastes the text.
10. **Elevated window.** Open Notepad with "Run as administrator" and dictate into it. Expected: the text is left on the clipboard, and the hint says the window runs as administrator.
11. **Recordings.** Tray > Open. Expected: Explorer opens `%LOCALAPPDATA%\Shepetal`. `audio\` has one WAV per dictation from the steps above, cancelled and too short ones included. Each plays as the clip you spoke.
12. **Start at login.** Tray > Start at login: the check mark goes away, and the `Shepetal` value is gone from `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (regedit). Click it again: the check is back. Sign out and in: Shepetal starts.
13. **Single instance.** Start Shepetal again from the Start menu. Expected: a dialog says it is already running, with no sound, and there is still one tray icon.
14. **Pause.** Tray > Pause, then hold Ctrl+Win and speak. Expected: nothing happens. Unpause, and dictation works again.
15. **Meeting.** With Shepetal running and idle for a minute, no card shows (its own open mic never counts). Join a Zoom call, or a Google Meet call in Chrome. Expected: about 5 s after the call takes the mic, a card above the 🤫 says "Meeting detected · Zoom" (or "· chrome") with Record and Not now, Windows asks for no permission, and nothing is recorded yet (no new folder in `%LOCALAPPDATA%\Shepetal\meetings`). Click Record: the call window keeps the focus (its title bar stays active), the card goes away and the hint says "Recording the meeting". Talk for a minute, then leave. Expected: about 4 s later the hint says where the meeting was saved, and that folder has Me.wav (your mic) and Others.wav (the call audio). Join again and click Not now: the card goes away, nothing is recorded, and no card comes back during that call. Join once more and wait: the card goes away by itself after 20 s. Outside a call, open the Camera app for 10 s: the card says "Meeting detected · WindowsCamera".
16. **Sign-in and trial.** Needs the account service live, or a local copy of it (`SHEPETAL_ACCOUNT_URL=http://localhost:3000`). Start a build that requires sign-in: `$env:SHEPETAL_REQUIRE_SIGNIN = "1"; & "$env:LOCALAPPDATA\Programs\Shepetal\shepetal.exe"`. Expected: after the mic and model steps, a dialog (no sound) offers "Sign in with Google to start your free 30-day trial". Click Sign in. Your default browser opens the Shepetal sign-in page; sign in with Google and click Continue. Expected: the tab says you can close it, the waiting dialog closes by itself, and a dialog says "Signed in as <you>" and "Free trial: 30 days left". The tray menu starts with "Free trial: 30 days left · <you>", then Get Shepetal for $4.99 and Sign out. Control Panel > Credential Manager > Windows Credentials lists `Shepetal/account`, and `%LOCALAPPDATA%\Shepetal\account.json` has no token in it. Dictation works.
17. **Signed out.** Tray > Sign out. Expected: the tray shows "Not signed in" and Sign in with Google, the credential is gone, and holding Ctrl+Win in Notepad records nothing (no red ring) and shows "Sign in with Google to start your free 30-day trial" next to the 🤫. Tray > Sign in with Google signs in again through the browser, and the hint says the days left.
18. **Offline and the 24 h check.** Signed in, turn on airplane mode and restart Shepetal. Expected: dictation still works, and the tray says the days left. In `account.json`, set `last_good_check` 8 days back (`[DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 8*86400`) and restart, still offline. Expected: Ctrl+Win shows "Connect to the internet so Shepetal can check your license". Turn the network back on and press Ctrl+Win again: within a minute, dictation works.
19. **Buy.** With a test-mode account service (Stripe test keys, never live), let the trial end (or use an account whose trial ended). Expected: Ctrl+Win shows "Trial ended: get Shepetal for $4.99", and the start dialog offers Get Shepetal. Tray > Get Shepetal for $4.99 opens Stripe Checkout in the browser. Pay with the test card 4242 4242 4242 4242. Expected: within about a minute the tray says "Yours forever · <you>" and Ctrl+Win dictates.
20. **Not required.** Start the default build without `SHEPETAL_REQUIRE_SIGNIN`, signed out. Expected: the first start offers sign-in once (Not now skips it, and later starts don't ask), and Ctrl+Win dictates while signed out.
21. **Quit and uninstall.** Tray > Quit: the 🤫 and the tray icon go away. Uninstall from Settings > Apps. Expected: no UAC prompt. `%LOCALAPPDATA%\Programs\Shepetal`, the Start menu entry, the Run value and `%LOCALAPPDATA%\Shepetal\models` are gone, and `%LOCALAPPDATA%\Shepetal\audio` and `meetings` are still there.

## Known limits

- **No fn key.** Windows keyboards don't report fn to apps, so the default hotkey is Ctrl+Win. `input::Hotkey::parse` takes others, but there is no setting for it yet.
- **Ctrl+Win+Space.** The hook swallows Space only while the hotkey is held and the 🤫 shows Recording or Hands-free, so the hands-free chord doesn't also switch the keyboard layout. While Shepetal is idle or paused, Windows' own Ctrl+Win+Space (switch layout) works as usual. Every other key passes through.
- **No history window and no retention setting.** Clips are kept (the "keep" default). The 24 h retention in `audio::Store::prune` and the history search, replay and re-transcribe are not wired to any UI yet. Tray > Open shows the folder.
- **Model tiers.** `shepetal-core::model` picks sherpa-onnx Parakeet tiers, but `audio` runs whisper.cpp only, so the app uses `audio::model::choose` (base.en q5_1 on the CPU, large-v3-turbo with the `cuda` feature). `base.en` is English only. None of this is measured on a Windows PC yet.
- **The mic shows as in use while Shepetal runs.** `audio::Mic` keeps the default mic open for its pre-roll, so the taskbar mic icon stays on. A change of the default mic needs a restart.
- **Task Manager's startup switch.** If you disable Shepetal under Task Manager > Startup apps, Windows records that separately (`StartupApproved`), and the tray's check mark does not show it.
- **Text around the cursor is not read**, so `shepetal_core::text::fit` (spacing and casing against the text before the cursor) is not applied. Only the cleanup runs.
- **An app that always holds the mic or the camera is one long meeting.** A voice-chat app idling in a channel, or a mic effects app such as NVIDIA Broadcast, gets one card when it starts and then none until it lets go.
- **The meeting card is mouse only.** It never takes focus, so the keyboard and screen readers can't reach it.
- **Quitting during a meeting** cuts its recording at that point. The WAV headers are rewritten after every batch, so both files stay playable up to there.
- **The account is not tested against the live service** yet: the service is not live, so the hand steps above need a local or test-mode copy. The uninstaller leaves the `Shepetal/account` credential and `account.json`; Sign out before uninstalling removes the credential.
- Single instance is per Windows session: two users who are signed in at once each get their own Shepetal.
