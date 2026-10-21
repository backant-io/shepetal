# shepetal

Local dictation for macOS. Hold `fn` to talk, double-tap `fn` for hands-free, and the text lands wherever your cursor is. Speech-to-text runs on your machine with the fastest model it can handle. Your audio and your text never leave your Mac. The only network calls are sign-in, the license check (at launch and once a day, never while you dictate) and checkout, all to shepetal.backant.io, and the one-time speech model download from the 🤫 menu. Signing in brings a sign-in window to the front, so a dictation running at that moment goes to the clipboard (focus moved).

An open-source replacement for Wispr Flow. Status: in design.

## Mac

### Install

From a release (exact click-by-click steps are in each release's notes):

1. Download `Shepetal-<version>.pkg` from the [Mac releases](https://github.com/backant-io/shepetal/releases).
2. Open it. The package is not signed (there is no Developer ID Installer certificate yet), so macOS may refuse it at first: right-click it › Open › Open. If macOS 15 offers no Open button, click Done, then System Settings › Privacy & Security › Open Anyway next to the Shepetal package, and confirm with your password.
3. Click through the installer (Continue, Install, your password). It installs `Shepetal.app` to `/Applications`, then, as you: sets System Settings › Keyboard › "Press 🌐 key to" to Do Nothing (so fn dictates instead of switching the input source), turns on Start at login, and opens Shepetal.
4. Shepetal runs in the menu bar (🤫) with no Dock icon, and a tiny 🤫 sits in the bottom-left corner of the screen. The permissions window asks for Microphone, Input Monitoring and Accessibility; grant all three.
5. Hold `fn` and talk in any app.

Shepetal also sets "Press 🌐 key to" to Do Nothing at every launch if it changed, and says so next to 🤫 once. The 🤫 menu's Restore 🌐 key setting puts your old value back (until Shepetal starts again). The zip (`Shepetal-<version>-mac.zip`) has the same app without the installer: drag it into `/Applications`.

Uninstall: run `/Applications/Shepetal.app/Contents/Resources/uninstall.sh` in Terminal. It quits Shepetal, turns Start at login off, restores the 🌐 key setting, and removes the app. Your recordings and history in `~/Library/Application Support/Shepetal` stay unless you add `--delete-data`.

From this checkout: `scripts/make-pkg.sh` builds the installer, `scripts/make-app.sh --install` builds the app and copies it to `/Applications/Shepetal.app` (it quits a running Shepetal first, opens it again afterwards, and removes an old `~/Applications` copy). A locally built app is not quarantined, so macOS does not block it.

Requirements: macOS 14 or later on Apple Silicon. The speech model (Parakeet v3, about 470 MB) downloads from the 🤫 menu on first run if it is not on the Mac yet. After that nothing goes over the network.

### Build from source

Requirements: Xcode or the Swift 6 toolchain.

```bash
swift build && swift test             # core: fn gestures, model tiers, languages, mic choice and health, dictionary, audio store, history, text rules
scripts/ci/run-checks.sh              # every suite in the repo, as CI runs them (--fast skips Docker and iOS; see docs/ci.md)
scripts/make-app.sh                   # dist/Shepetal.app (menu-bar only), signed (see below)
scripts/make-app.sh --install         # same, then installed to /Applications/Shepetal.app
scripts/make-app.sh --zip             # same, plus dist/Shepetal-<version>-mac.zip for a release
scripts/make-pkg.sh                   # the installer dist/Shepetal-<version>.pkg (--test: a package that changes nothing)
scripts/test-pkg-scripts.sh           # postinstall and uninstaller against stand-ins: 🌐 key, login item, open, restore
open dist/Shepetal.app                # add --args --no-permission-prompts to never ask macOS for anything
scripts/check-app.sh                  # launches "Shepetal Check.app" (separate bundle ID, no permissions): menu-bar only, 🤫 bottom-left, alive for 5 min, Quit from the menu
scripts/e2e-mac.sh                    # real pipeline on `say` speech: WER, latency, audio file, app and re-transcribe checks
sandbox-exec -p '(version 1)(allow default)(deny network*)' scripts/e2e-mac.sh   # same, with the network blocked
```

`scripts/make-app.sh` signs with the first Developer ID Application or Apple Development certificate in your keychain, or with `SIGN_IDENTITY`. With a certificate, macOS keeps the permissions you granted across rebuilds. Without one it signs ad-hoc, and macOS asks for the permissions again after every rebuild.

### Use

- Hold `fn` to talk and release to insert. Double-tap `fn` for hands-free, then tap `fn` once to stop. A press shorter than 0.5 s inserts nothing and shows a hint. Another key pressed in the first second of an fn hold (fn+Delete, fn+arrows) is a shortcut, so that recording is cancelled.
- fn+Space starts hands-free, or locks a hold you already started; press it again to stop (within 0.5 s of the start it cancels). Esc cancels a recording or a transcription and keeps its audio. ⌃⌘V pastes the last text and ⌃⌘C copies it, also from the 🤫 menu. Shortcuts… in the menu rebinds each action to up to 3 keys, which must include a modifier, fn or a mouse button (3 to 10). With Accessibility, Shepetal keeps Esc and the shortcut keys from the app you are in.
- A dictation stops by itself after 20 minutes and is inserted, with "1 minute left" shown a minute before. `defaults write io.backant.shepetal maxDictationMinutes -int N` changes the cap.
- 🤫 sits 8 pt in from the bottom-left corner of the main display while Shepetal runs. A red ring means recording, orange hands-free, a pulsing blue ring processing, and yellow an error, with a short message next to it.
- Speech-to-text runs locally: Parakeet TDT 0.6B v3 through FluidAudio, from FluidAudio's model cache (`~/Library/Application Support/FluidAudio/Models`). If it is missing, the 🤫 menu offers the download (about 470 MB). The fallback from `docs/models.md` is whisper.cpp: put `whisper-cli` in `~/Library/Application Support/Shepetal/models/whisper.cpp/` and the `ggml-*.bin` model next to it, or set `SHEPETAL_WHISPER_CLI` and `SHEPETAL_WHISPER_MODEL`.
- 🤫 > Microphone: Automatic, a device to force, or "Prefer <name>" to move it to the top of your ranking. The choice runs on every dictation: forced device, then the first ranked device that is plugged in, then the system default, never the built-in mic while the lid is closed. A dead mic, an unplugged mic, a Bluetooth mic or a very quiet recording each get a short note next to 🤫; the audio is kept either way.
- Voice Isolation: the speech model hears every dictation through Apple's sound-isolation effect (AUSoundIsolation), and the kept WAV stays the raw recording. Shepetal never turns on macOS voice processing or opens the Mic Mode picker, so it never shows up there. `defaults write io.backant.shepetal voiceIsolationMix -float <0-100>` tunes the effect (default 100; see #75 and M-MIC-6).
- 🤫 > Languages: Automatic uses Parakeet, as does any set of its 25 European languages. Other languages use Whisper large-v3-turbo (see `docs/models.md`).
- 🤫 > Dictionary… opens `dictionary.txt` (owner-only) in your editor: one word or phrase per line to fix its spelling and casing, `spoken => written` for a replacement, `*` to star, `#` for comments. It applies from the next dictation. No entries ship by default.
- Text goes in through the clipboard and a synthesized Cmd+V. Shepetal checks that an app took the text, then puts your clipboard back about 0.5 s later.
- The text is pasted only if the window you started in is still in focus, and Shepetal never moves focus back. If you clicked into another window, or the paste does not land, the text is left on the clipboard and the note next to 🤫 says to press ⌘V. The text fits the cursor's line: a space before it when needed, a non-breaking space before a following word, and lowercase mid-sentence (names keep their capital), with no period of its own when the sentence goes on after the cursor. Electron apps such as VS Code and Slack are asked for their accessibility tree when the dictation starts, so their fields can be read too. When the field cannot be read, the text goes in as dictated. Over a selection, it takes the selection's case, end punctuation and surrounding spaces.
- When another app has secure input on (a password field, Terminal's Secure Keyboard Entry), a note next to 🤫 says so. Nothing is pasted then: the text is left on the clipboard for ⌘V. A permission turned off while Shepetal runs shows a message and opens the Permissions window, and the yellow ring clears once it is back on.
- The 🤫 menu has Start at login (the installer turns it on). Shepetal makes no sounds; the 🤫 ring colors show the state.
- Every recording is kept as a 16 kHz mono WAV in `~/Library/Application Support/Shepetal/audio` (folder 0700, files 0600). That includes too-short and failed ones, which are flagged in the history. The history is `history.sqlite` in the same folder. Under Recordings in the menu you can keep everything (the default) or delete recordings after 24 hours. `SHEPETAL_HOME` moves the whole folder.
- Open Shepetal… in the 🤫 menu, or opening the app again while it runs, shows the Shepetal window. Home has your account first (who is signed in, the trial or license, with Sign in, Buy and Sign out), then the speech recognition engine (standard or alternative), whether `fn` is watched, missing permissions, and the Donate links. History has search, copy, play, re-transcribe (with the engine in use or the other installed one) and archive. The app never shows model names; they are in this README, `docs/models.md` and the log. Settings has recordings retention, the recordings folder and permissions. Each dictation records the app it went to and, in Safari, Chrome, Arc, Edge, Brave, Firefox, Vivaldi or Opera, the page URL. Both stay in `history.sqlite`.
- Account: sign in once with Google from the 🤫 menu or Home to start a free 30-day trial (no credit card). Sign-in opens shepetal.backant.io in a macOS sign-in sheet that shares your browser's Google login (OAuth for native apps with PKCE, RFC 8252 and RFC 7636: nothing to type, no code to copy); the sign-in token is kept in the Keychain (service `io.backant.shepetal.account`). After the trial, Shepetal is $4.99 once for a lifetime license with future updates. The menu and the top of Home say who is signed in and the days left or "Yours forever" ("Signed in as you@example.com · Trial, 12 days left"), with Sign out. When not signed in or after the trial, Shepetal opens its window on Home once at launch, `fn` only shows a hint next to 🤫 and opens Home (the mic stays off), and Get Shepetal for $4.99 opens checkout. The license is checked at launch and every 24 hours, in the background and never during a dictation. The last answer is cached in `account.json` and holds for 7 days offline. `SHEPETAL_ACCOUNT_URL` points the app at another account service. Release builds require sign-in: `scripts/make-pkg.sh` and `scripts/make-app.sh --zip` set `ShepetalRequiresSignIn` in Info.plist. A build from source does not (`REQUIRE_SIGNIN=1 scripts/make-app.sh` turns it on), so it offers sign-in but dictates without it. `SHEPETAL_REQUIRE_SIGNIN=1` or `0` overrides either when the app starts.
- Meetings: Shepetal notices a call in Zoom, Teams, Slack huddles, FaceTime, Webex, Discord, or Google Meet, Teams and Zoom in the browser (these need Screen Recording access), and asks first. A small card above 🤫 says "Meeting detected · Zoom" with Record and Not now; it takes the click without taking focus from the app you are in, and goes away after 20 s. Nothing records until you click Record. Not now, or letting the card go, records nothing for that meeting. Settings has "Always record meetings automatically" (off by default) to skip the question. While a meeting records, 🤫 has a red ring the whole time (through dictations too), the menu bar shows 🤫●, and the 🤫 menu has Stop meeting recording; Start meeting recording records by hand. Your mic and the call audio are kept as `Me.wav` and `Others.wav` in `~/Library/Application Support/Shepetal/meetings` (folder 0700, files 0600), transcribed on the Mac and summarized without an LLM; the Meetings tab in Open Shepetal… lists them.
- Permissions: Microphone, Input Monitoring (to see `fn`) and Accessibility (to paste). The Permissions window shows each one and opens its System Settings pane.
- Manual checks are listed in [docs/manual-test.md](docs/manual-test.md#mac).

## Sponsors

shepetal is built by one developer and a fleet of agents. Sponsorship pays for the time it takes to keep it fast and free.

<a href="https://github.com/sponsors/backant-io"><img src="https://img.shields.io/badge/GitHub%20Sponsors-sponsor%20shepetal-EA4AAA?logo=githubsponsors&logoColor=white" alt="Sponsor on GitHub"></a>
<a href="https://buymeacoffee.com/sorcecoder"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-sorcecoder-FFDD00?logo=buymeacoffee&logoColor=black" alt="Buy Me a Coffee"></a>

## License

MIT, see [LICENSE](LICENSE).
