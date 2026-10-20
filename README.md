# shepetal

Local dictation for macOS. Hold `fn` to talk, double-tap `fn` for hands-free, and the text lands wherever your cursor is. Speech-to-text runs on your machine with the fastest model it can handle. Your audio and your text never leave your Mac. The only network calls are sign-in, the license check (at launch and once a day, never while you dictate) and checkout, all to shepetal.backant.io, and the one-time speech model download from the 🤫 menu.

An open-source replacement for Wispr Flow. Status: in design.

## Mac

Requirements: macOS 14 or later, Apple Silicon for the default model, Xcode or the Swift 6 toolchain.

```bash
swift build && swift test             # core: fn gestures, model tiers, audio store, history, text rules
scripts/make-app.sh                   # dist/Shepetal.app (menu-bar only, ad-hoc signed)
open dist/Shepetal.app                # add --args --no-permission-prompts to never ask macOS for anything
scripts/e2e-mac.sh                    # real pipeline on `say` speech: WER, latency, audio file, app and re-transcribe checks
sandbox-exec -p '(version 1)(allow default)(deny network*)' scripts/e2e-mac.sh   # same, with the network blocked
```

- Hold `fn` to talk and release to insert. Double-tap `fn` for hands-free, then tap `fn` once to stop. A press shorter than 0.5 s inserts nothing and shows a hint. Another key pressed in the first second of an fn hold (fn+Delete, fn+arrows) is a shortcut, so that recording is cancelled.
- 🤫 sits 8 pt in from the bottom-left corner of the main display while Shepetal runs. A red ring means recording, orange hands-free, a pulsing blue ring processing, and yellow an error, with a short message next to it.
- Speech-to-text runs locally: Parakeet TDT 0.6B v3 through FluidAudio, from FluidAudio's model cache (`~/Library/Application Support/FluidAudio/Models`). If it is missing, the 🤫 menu offers the download (about 470 MB). The fallback from `docs/models.md` is whisper.cpp: put `whisper-cli` in `~/Library/Application Support/Shepetal/models/whisper.cpp/` and the `ggml-*.bin` model next to it, or set `SHEPETAL_WHISPER_CLI` and `SHEPETAL_WHISPER_MODEL`.
- Text goes in through the clipboard and a synthesized Cmd+V. Shepetal checks that an app took the text, then puts your clipboard back about 0.5 s later.
- The text is pasted only if the window you started in is still in focus, and Shepetal never moves focus back. If you clicked into another window, or the paste does not land, the text is left on the clipboard and the note next to 🤫 says to press ⌘V. The text fits the cursor's line: a space before it when needed, a non-breaking space before a following word, and lowercase mid-sentence. Over a selection, it takes the selection's case, end punctuation and surrounding spaces.
- When another app has secure input on (a password field, Terminal's Secure Keyboard Entry), a note next to 🤫 says so. Nothing is pasted then: the text is left on the clipboard for ⌘V. A permission turned off while Shepetal runs shows a message and opens the Permissions window, and the yellow ring clears once it is back on.
- The 🤫 menu has Sounds (short start, stop, hands-free and cancel sounds made in code, on by default) and Open at login. The start sound plays once fn has been held for 0.5 s, so a short tap or an fn shortcut makes no sound.
- Every recording is kept as a 16 kHz mono WAV in `~/Library/Application Support/Shepetal/audio` (folder 0700, files 0600). That includes too-short and failed ones, which are flagged in the history. The history is `history.sqlite` in the same folder. Under Recordings in the menu you can keep everything (the default) or delete recordings after 24 hours. `SHEPETAL_HOME` moves the whole folder.
- Open Shepetal… in the 🤫 menu, or opening the app again while it runs, shows the Shepetal window. Home has the speech recognition engine (standard or alternative), whether `fn` is watched, missing permissions, your trial or license with Sign in, Buy and Sign out, and the Donate links. History has search, copy, play, re-transcribe (with the engine in use or the other installed one) and archive. The app never shows model names; they are in this README, `docs/models.md` and the log. Settings has recordings retention, the recordings folder and permissions. Each dictation records the app it went to and, in Safari, Chrome, Arc, Edge, Brave, Firefox, Vivaldi or Opera, the page URL. Both stay in `history.sqlite`.
- Account: sign in once from the 🤫 menu or Home to start a free 30-day trial (no credit card). Sign-in opens shepetal.backant.io in your browser with a code to confirm; the sign-in token is kept in the Keychain (service `io.backant.shepetal.account`). After the trial, Shepetal is $4.99 once for a lifetime license with future updates. The menu and Home show the days left or "Yours forever". When not signed in or after the trial, `fn` only shows a hint, and Get Shepetal for $4.99 opens checkout. The license is checked at launch and every 24 hours, in the background and never during a dictation. The last answer is cached in `account.json` and holds for 7 days offline. `SHEPETAL_ACCOUNT_URL` points the app at another account service.
- Permissions: Microphone, Input Monitoring (to see `fn`) and Accessibility (to paste). The Permissions window shows each one and opens its System Settings pane.
- Manual checks are listed in [docs/manual-test.md](docs/manual-test.md#mac).

## Sponsors

shepetal is built by one developer and a fleet of agents. Sponsorship pays for the time it takes to keep it fast and free.

<a href="https://github.com/sponsors/backant-io"><img src="https://img.shields.io/badge/GitHub%20Sponsors-sponsor%20shepetal-EA4AAA?logo=githubsponsors&logoColor=white" alt="Sponsor on GitHub"></a>
<a href="https://buymeacoffee.com/sorcecoder"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-sorcecoder-FFDD00?logo=buymeacoffee&logoColor=black" alt="Buy Me a Coffee"></a>

## License

MIT, see [LICENSE](LICENSE).
