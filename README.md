# shepetal

Local dictation for macOS. Hold `fn` to talk, double-tap `fn` for hands-free, and the text lands wherever your cursor is. Speech-to-text runs on your machine with the fastest model it can handle. Nothing leaves your computer.

An open-source replacement for Wispr Flow. Status: in design.

## Mac

Requirements: macOS 14 or later, Apple Silicon for the default model, Xcode or the Swift 6 toolchain.

```bash
swift build && swift test             # core: fn gestures, model tiers, audio store, history, text rules
scripts/make-app.sh                   # dist/Shepetal.app (menu-bar only, ad-hoc signed)
open dist/Shepetal.app                # add --args --no-permission-prompts to never ask macOS for anything
scripts/e2e-mac.sh                    # real pipeline on `say` speech: WER, latency, audio file checks
sandbox-exec -p '(version 1)(allow default)(deny network*)' scripts/e2e-mac.sh   # same, with the network blocked
```

- Hold `fn` to talk and release to insert. Double-tap `fn` for hands-free, then tap `fn` once to stop. A press shorter than 0.5 s inserts nothing and shows a hint. Another key pressed in the first second of an fn hold (fn+Delete, fn+arrows) is a shortcut, so that recording is cancelled.
- 🤫 sits 8 pt in from the bottom-left corner of the main display while Shepetal runs. A red ring means recording, orange hands-free, a pulsing blue ring processing, and yellow an error, with a short message next to it.
- Speech-to-text runs locally: Parakeet TDT 0.6B v3 through FluidAudio, from FluidAudio's model cache (`~/Library/Application Support/FluidAudio/Models`). If it is missing, the 🤫 menu offers the download (about 470 MB). The fallback from `docs/models.md` is whisper.cpp: put `whisper-cli` in `~/Library/Application Support/Shepetal/models/whisper.cpp/` and the `ggml-*.bin` model next to it, or set `SHEPETAL_WHISPER_CLI` and `SHEPETAL_WHISPER_MODEL`.
- Text goes in through the clipboard and a synthesized Cmd+V. Shepetal checks that an app took the text, then puts your clipboard back about 0.5 s later.
- Every recording is kept as a 16 kHz mono WAV in `~/Library/Application Support/Shepetal/audio` (folder 0700, files 0600). That includes too-short and failed ones, which are flagged in the history. The history is `history.sqlite` in the same folder. Under Recordings in the menu you can keep everything (the default) or delete recordings after 24 hours. `SHEPETAL_HOME` moves the whole folder.
- Permissions: Microphone, Input Monitoring (to see `fn`) and Accessibility (to paste). The Permissions window shows each one and opens its System Settings pane.
- Manual checks are listed in [docs/manual-test.md](docs/manual-test.md#mac).

## Sponsors

shepetal is built by one developer and a fleet of agents. Sponsorship pays for the time it takes to keep it fast and free.

<a href="https://github.com/sponsors/backant-io"><img src="https://img.shields.io/badge/GitHub%20Sponsors-sponsor%20shepetal-EA4AAA?logo=githubsponsors&logoColor=white" alt="Sponsor on GitHub"></a>
<a href="https://buymeacoffee.com/sorcecoder"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-sorcecoder-FFDD00?logo=buymeacoffee&logoColor=black" alt="Buy Me a Coffee"></a>

## License

MIT, see [LICENSE](LICENSE).
