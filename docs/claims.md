# Claims

The landing page says two things about privacy: "100% private. Your data is yours." and "Works offline." The
Claims workflow, [.github/workflows/claims.yml](../.github/workflows/claims.yml), checks both in public on a
GitHub-hosted Mac (`macos-26`, Apple Silicon): on every pull request and push to main that touches `Sources/`,
`Package.*`, `scripts/e2e-*.sh` or the workflow, every Monday, and on demand (Actions > Claims > Run workflow). It
needs no secrets, so anyone can read its logs and anyone with a fork can run it.

## The sandbox profile

```
(version 1)(allow default)(deny network* (with send-signal SIGKILL))
```

This is macOS's own sandbox (`sandbox-exec`). It allows everything except network use: no TCP or UDP connection, no
DNS lookup (that goes through a socket to mDNSResponder), no listening socket. A process that tries one is killed on
the spot (`SIGKILL`), so a network attempt fails the run whatever the code does with the error: `scripts/e2e-mac.sh`
and `scripts/e2e-meeting.sh` fail when shepetal exits with anything but 0 or 1 (137 is `SIGKILL`). The profile is
inherited by every process started inside it, so shepetal's own process and the processes it spawns run without the
network. A denial is also reported to the unified log as `Sandbox: <process>(<pid>) deny(1) network-...`, but the
log can drop reports: in run 39889902952 the log holds only "duplicate report" lines for `shepetal(7056)`, not the
reports they duplicate. That is why the profile kills the process instead of leaving the check to the log.

## Works offline

Job `claims`, steps **Dictation, network denied** and **Meeting, network denied**.

1. With the network on, the workflow fetches the speech model, Parakeet TDT 0.6B v3 (about 470 MB), the way
   `bench/fluid` does it: FluidAudio's own `AsrModels.download` into FluidAudio's cache, where the app loads it from.
   It is cached on the FluidAudio pins (`Package.resolved` and `bench/fluid/Package.resolved`), so later runs do
   not download it. Then it builds shepetal
   (`swift build -c release`).
2. With the network denied, it runs `scripts/e2e-mac.sh` under the profile above. That is the real dictation
   pipeline on speech made with `say`: the capture resampler, the speech model, cleanup (rules), the dictionary,
   the audio store, history, re-transcribe, and the paste into a text view the test owns, through a private
   pasteboard. It asserts the word error rate (at most 8 %), the text that lands, owner-only audio files and folders,
   the app and page recorded in history, nothing pasted for silence, and the text left on the clipboard when a paste
   does not land. One check is relaxed for CI, and the log says so: `LATENCY=report` prints the time from release to
   text and asserts a loose 2000 ms bar instead of the 700 ms one (`NOT ASSERTED: the 700 and 800 ms bars ...`), so
   a gross slowdown still fails. GitHub's Macs are virtual machines with no Neural Engine; the times are below.
   Speed is not one of these two claims; without the switch, on a real Mac, the 700 ms bar is asserted as before. One
   fixture differs from its text on purpose: the voice on GitHub's Macs reads "finance lead" in e01 as the metal, so
   `say` is given "leed"; the reference text is still "lead".
3. Then `scripts/e2e-meeting.sh`, which runs shepetal under the same profile itself: a two-voice meeting through the
   real transcriber, store and summarizer. It asserts both speakers at the right times, at least 80 % of each
   speaker's words, the meeting read back from the store and found by search, owner-only audio, and a summary with
   an action item. The script is not wrapped in a second sandbox, because macOS cannot apply a sandbox inside
   another.

A pass means the dictation and meeting paths work with no network for shepetal's own process and the processes it
spawns, and that none of them tried the network (a try kills the process).

Ready times on the macos-26 runs of the pull request that added this workflow that reached the dictation results
(39886776416, 39888350903, 39888837394, 39889902952, 39890403775, 39890846701, 39892997881, 39894259075; run ids
under https://github.com/backant-io/shepetal/actions/runs/):

| Clip | Fastest | Slowest |
|---|---|---|
| e01 | 337 ms (39889902952) | 836 ms (39894259075) |
| e01-quiet | 374 ms (39886776416) | 1075 ms (39894259075) |
| e02 | 329 ms (39890403775) | 703 ms (39894259075) |
| e03 | 306 ms (39888350903) | 875 ms (39888837394) |
| e04 | 349 ms (39888350903) | 736 ms (39894259075) |
| e05 | 429 ms (39889902952) | 1063 ms (39892997881) |
| e06 | 319 ms (39889902952) | 646 ms (39892997881) |

In the first six runs every value over the 700 ms bar (e01-quiet 995 ms, e03 875 ms) came from run 39888837394,
one of the two runs carrying the throwaway request below (39888837394 and 39889902952), and the clean runs stayed
under 570 ms. The two clean runs after them, with the app's code unchanged, went over it: e05 took 1063 ms in
39892997881, and every clip but e06 was over 700 ms in 39894259075. The VMs' speed changes from run to run, which
is why the 700 ms bar is not asserted there; every value is under the 2000 ms CI bar.

## 100% private

Job `claims`, step **Nothing leaves the Mac**.

Denying the network alone would prove the work does not need it, not that nothing tries: a request that fails
quietly would still pass. The kill closes that gap: the first network attempt kills the process that makes it, and
the e2e fails. That is the check. The log is the printed witness: after the runs the workflow reads the unified log
for the run window (`log show --start <time the runs began>`), prints every network-related denial on the Mac in
that window, and fails on any `deny(N) network-...` line from any process but the canary, so a child process (curl,
a helper) is caught too. It also fails if the e2e output shows a network error (`NSURLErrorDomain`, `nw_connection`
and the like). Lines from macOS's own daemons (for example `mobileassetd` reading a network preferences file,
`deny(1) file-read-data`) come from their own sandboxes, not from this run's profile, and do not match.

Two things keep that check honest:

- A canary at the start of the run: `curl https://example.com` under the plain profile
  `(version 1)(allow default)(deny network*)` (no kill, so curl lives to fail) must fail, and its denial, found by
  curl's pid, must be in the log. The log can drop the canary's report too (run 39894847241 failed that way), so the
  workflow tries up to three curls, each a new pid, and needs one of them in the log. If the sandbox let curl
  through, or the log showed none of them, the job fails instead of passing on an empty log. On GitHub's macos-15 Macs the canary's denial did not show in the log, which
  is one reason the workflow runs on macos-26.
- The checks were shown to fail on the pull request that added this workflow. First the log check alone, under the
  profile without the kill: a throwaway commit (954a1a2) sent one request to https://example.com after each
  dictation. Dictation and meeting still passed, and **Nothing leaves the Mac** went red and printed the denials
  (`1 duplicate report for Sandbox: shepetal(7056) deny(1) network-outbound remote:*:443`):
  https://github.com/backant-io/shepetal/actions/runs/39889902952 (on 1b75500, which still carried 954a1a2's
  change). The commit was reverted (`git revert`) and the next run went green:
  https://github.com/backant-io/shepetal/actions/runs/39890403775. Then with the kill: a throwaway commit (83121ae)
  made one URLSession request to https://example.com, once, after the first dictation. The sandbox killed shepetal
  and the dictation e2e failed (`e2e-mac: shepetal exited 137`); **Nothing leaves the Mac** printed
  `Sandbox: shepetal(10122) deny(1) network-outbound`: https://github.com/backant-io/shepetal/actions/runs/39893739121.
  Reverted (a0d5de2), green: https://github.com/backant-io/shepetal/actions/runs/39894259075.

`scripts/e2e-mac.sh` checks that llama.framework and whisper.framework do not import `socket`, `connect`,
`getaddrinfo`, `gethostbyname` or `curl_*` (`nm -u`).

## What this covers

- Dictation: the whole path from audio to the text in the field, with the rules cleanup.
- Meetings: transcription of both channels, the store, search and the summary with action items.
- That shepetal's own process and the processes it spawns make no network attempt in those paths, on the code at
  that commit.

## What this does not cover

- The cleanup model (Qwen3.5, about 1.3 GB). The workflow runs `e2e-mac.sh` with `CLEANUP=rules`, which skips the
  clips that need it and says `SKIPPED: cleanup clips (CLEANUP=rules)` in the log. Its library (llama.framework)
  imports none of the network calls above (`nm -u`), and the full run with the model is part of the local check before a change to the pipeline lands.
- Languages: whisper large-v3-turbo (about 574 MB) and the language checks. `LANGUAGES=skip` skips them and says
  `SKIPPED: languages (LANGUAGES=skip)`.
- c05, the 800 ms bar with a full text field: it is a cleanup clip, so `CLEANUP=rules` skips it too.
- Microphone capture, the `fn` key, the menu bar and the windows. The e2e feeds audio files to the same pipeline and
  pastes into its own text view, because a CI Mac has no microphone and no one to grant permissions.
- Features that use the network by design and are not part of dictation or meetings: sign-in, the license check (at
  launch and once a day, never during a dictation), checkout and the account pages on shepetal.app, the update check,
  and the downloads you start from the 🤫 menu (the speech model, the cleanup model, dictionary support, translation
  languages). The README lists them.
- Network work that macOS services or other apps do for shepetal over XPC or LaunchServices runs outside the
  profile: `nsurlsessiond` background sessions, `mobileassetd` asset downloads (such as NaturalLanguage assets), a
  URL opened in the browser. The runner itself stays online; only the processes under the profile are cut off.
- The signed release build. The workflow builds from source at that commit; it does not test the DMG you download.
