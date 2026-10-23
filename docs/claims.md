# Claims

The landing page says two things about privacy: "100% private. Your data is yours." and "Works offline." The
Claims workflow, [.github/workflows/claims.yml](../.github/workflows/claims.yml), checks both in public on a
GitHub-hosted Mac (`macos-26`, Apple Silicon): on every pull request and push to main that touches `Sources/`,
`Package.*`, `scripts/e2e-*.sh` or the workflow, every Monday, and on demand (Actions > Claims > Run workflow). It
needs no secrets, so anyone can read its logs and anyone with a fork can run it.

## The sandbox profile

```
(version 1)(allow default)(deny network*)
```

This is macOS's own sandbox (`sandbox-exec`). It allows everything except network use: no TCP or UDP connection, no
DNS lookup (that goes through a socket to mDNSResponder), no listening socket. The profile is inherited by every
process started inside it, so shepetal and everything it starts run without the network. Every denial is written to
the unified log as `Sandbox: <process>(<pid>) deny(1) network-...`.

## Works offline

Job `claims`, steps **Dictation, network denied** and **Meeting, network denied**.

1. With the network on, the workflow fetches the speech model, Parakeet TDT 0.6B v3 (about 470 MB), the way
   `bench/fluid` does it: FluidAudio's own `AsrModels.download` into FluidAudio's cache, where the app loads it from.
   It is cached on the FluidAudio version, so later runs do not download it. Then it builds shepetal
   (`swift build -c release`).
2. With the network denied, it runs `scripts/e2e-mac.sh` under the profile above. That is the real dictation
   pipeline on speech made with `say`: the capture resampler, the speech model, cleanup (rules), the dictionary,
   the audio store, history, re-transcribe, and the paste into a text view the test owns, through a private
   pasteboard. It asserts the word error rate (at most 8 %), the text that lands, owner-only audio files and folders,
   the app and page recorded in history, nothing pasted for silence, and the text left on the clipboard when a paste
   does not land. One check is relaxed for CI, and the log says so: `LATENCY=report` prints the time from release to
   text instead of asserting the 700 ms bar (`NOT ASSERTED: the 700 and 800 ms bars ...`). GitHub's Macs are
   virtual machines with no Neural Engine, and the same clips took 243 to 995 ms there from one run to the next.
   Speed is not one of these two claims; without the switch, on a real Mac, the bar is asserted as before. One
   fixture differs from its text on purpose: the voice on GitHub's Macs reads "finance lead" in e01 as the metal, so
   `say` is given "leed"; the reference text is still "lead".
3. Then `scripts/e2e-meeting.sh`, which runs shepetal under the same profile itself: a two-voice meeting through the
   real transcriber, store and summarizer. It asserts both speakers at the right times, at least 80 % of each
   speaker's words, the meeting read back from the store and found by search, owner-only audio, and a summary with
   an action item. The script is not wrapped in a second sandbox, because macOS cannot apply a sandbox inside
   another.

A pass means the dictation and meeting paths work with no network at all.

## 100% private

Job `claims`, step **Nothing leaves the Mac**.

Denying the network proves the work does not need it. It does not prove that nothing tries: a request that fails
quietly would still pass the steps above. So after the runs the workflow reads the unified log for the run window
(`log show --start <time the runs began>`) and fails if any network denial belongs to a `shepetal` process, and
prints it. It also fails if the e2e output shows a network error (`NSURLErrorDomain`, `nw_connection` and the like).
The step prints every network-related denial on the Mac in that window. Lines from macOS's own daemons (for example
`mobileassetd` reading a network preferences file) come from their own sandboxes, not from this run's profile.

Two things keep that check honest:

- A canary at the start of the run: `curl https://example.com` under the same profile must fail, and its denial must
  be in the log. If the sandbox let curl through, or the log no longer showed denials, the job fails instead of
  passing on an empty log. On GitHub's macos-15 Macs the canary's denial did not show in the log, which is one reason
  the workflow runs on macos-26.
- The check was shown to fail: a throwaway commit on the pull request that added this workflow sent one request to
  https://example.com after each dictation. Dictation and meeting still passed, and **Nothing leaves the Mac** went
  red and printed the denials (`Sandbox: shepetal(7056) deny(1) network-outbound remote:*:443`):
  https://github.com/backant-io/shepetal/actions/runs/39889902952. The commit was reverted (`git revert`) and the
  next run went green: https://github.com/backant-io/shepetal/actions/runs/39890403775.

The e2e scripts also check that the cleanup model's and whisper's libraries (llama.cpp, whisper.cpp) link no socket
or DNS call at all.

## What this covers

- Dictation: the whole path from audio to the text in the field, with the rules cleanup.
- Meetings: transcription of both channels, the store, search and the summary with action items.
- That nothing in those paths tries the network, on the code at that commit.

## What this does not cover

- The cleanup model (Qwen3.5, about 1.3 GB). The workflow runs `e2e-mac.sh` with `CLEANUP=rules`, which skips the
  clips that need it and says `SKIPPED: cleanup clips (CLEANUP=rules)` in the log. Its library links no network call
  (checked above), and the full run with the model is part of the local check before a change to the pipeline lands.
- Languages: whisper large-v3-turbo (about 574 MB) and the language checks. `LANGUAGES=skip` skips them and says
  `SKIPPED: languages (LANGUAGES=skip)`.
- c05, the 800 ms bar with a full text field: it is a cleanup clip, so `CLEANUP=rules` skips it too.
- Microphone capture, the `fn` key, the menu bar and the windows. The e2e feeds audio files to the same pipeline and
  pastes into its own text view, because a CI Mac has no microphone and no one to grant permissions.
- Features that use the network by design and are not part of dictation or meetings: sign-in, the license check (at
  launch and once a day, never during a dictation), checkout and the account pages on shepetal.app, the update check,
  and the downloads you start from the 🤫 menu (the speech model, the cleanup model, dictionary support, translation
  languages). The README lists them.
- The signed release build. The workflow builds from source at that commit; it does not test the DMG you download.
