# Meeting recording on Linux

`shepetal daemon` records meetings on its own (goal rule 7). The code is in
`linux/src/meeting_rec.rs`, and the pw-dump parsing it uses is in `linux/src/meeting.rs`.

## What it does

1. Every 2 s it runs `pw-dump` and lists the meeting apps that are capturing the mic: running
   `Stream/Input/Audio` nodes that are not on a sink monitor, matched to Zoom, Teams, Slack,
   Discord, Chrome/Chromium or Firefox. shepetal's own streams never count. They are named
   `shepetal`, and Others.wav records a monitor. If `pw-dump` is missing, or both `pw-record`
   and `parecord` are, the daemon says so at startup and records no meetings.
2. Once a meeting app has held the mic for the start grace, it creates
   `$XDG_DATA_HOME/shepetal/meetings/<unix-ms>/` (default `~/.local/share/...`) and records two
   16 kHz mono WAVs there:
   - `Me.wav`: the default mic.
   - `Others.wav`: the default sink's monitor, which is what you hear.
   It uses `pw-record`, and `parecord` when pw-record is missing. For Others.wav,
   `pw-record -P '{ stream.capture.sink = true }'` lets WirePlumber link it to the default
   sink's monitor and move it when the default sink changes. `parecord` uses
   `--device=@DEFAULT_MONITOR@`.
3. When every meeting app has let go of the mic, it waits out the end thresholds, stops both
   recorders with SIGINT (so the WAV header is written) and starts transcribing on another
   thread. Detection goes on meanwhile.
4. It runs `whisper-cli` on each file, keeping the segment times, and writes `transcript.md` next
   to the audio:

   ```
   # Meeting

   - Apps: Zoom
   - Audio: Me.wav (microphone), Others.wav (system audio)

   [00:00:01] Me: Hello, can you hear me?

   [00:00:03] Others: Yes, loud and clear.
   ```

   Times count from the start of the recording. Consecutive segments from one speaker are
   joined into one turn. If a channel can't be transcribed, the reason is listed in the header
   and the other channel is still written.

The audio is always kept. Nothing is deleted, and nothing leaves the machine.

## Thresholds

These are the values from docs/re/meetings.md (sections 2.3 and 2.4), the same as the Mac's
`MeetingDetector`. Override them in seconds with `SHEPETAL_MEETING_THRESHOLDS`, for example
`SHEPETAL_MEETING_THRESHOLDS="reacquire=8,start_after=3"`. A bad value stops the daemon with
an error.

| Name | Default | Meaning |
| --- | --- | --- |
| `poll` | 2 | Seconds between `pw-dump` reads |
| `start_after` | 5 | How long a meeting app must hold the mic before recording starts. A miss starts the count again |
| `min_session` | 15 | No end in the first 15 s of a recording |
| `end_with_evidence` | 3 | Wait after the last meeting app lets go of the mic (bound silence) |
| `reacquire` | 4 | If the mic comes back within this time, it is the same meeting. The end waits for the longer of this and `end_with_evidence` |
| `device_change` | 10 | A change of the default mic or speakers holds off an end this long |

On Linux the mic holder is the only evidence, so every end is the bound kind. The 30 s unbound
silence never applies.

## Speech-to-text

The final pass is Whisper on the whole files (docs/re/meetings.md section 7). It uses the
dictation model when that is Whisper (Vulkan machines). On every other machine it uses
`~/.local/share/shepetal/ggml-large-v3-turbo-q5_0.bin`. When `whisper-cli` or that model is
missing, the daemon says so at startup. Meetings are still recorded, and the transcript lists
the error.

## Security

- The `meetings` directory and each meeting folder are 0700. `Me.wav`, `Others.wav` and
  `transcript.md` are 0600 and created with `O_CREAT|O_EXCL`, so an existing folder or file
  (or a planted symlink) is never reused or overwritten.
- A `meetings` directory that is a symlink or open to others is refused, and nothing is
  recorded. The audio lives under the data home, never `/tmp`. An empty or relative
  `XDG_DATA_HOME` is ignored, as for dictation.
- The recorders get SIGINT (`PR_SET_PDEATHSIG`) when the daemon exits, even by SIGKILL, so a
  dead daemon never leaves the mic recording. For dictation, that gap is still open (#45).

## Tests

`cargo test` in `linux/` runs `meeting_rec::tests`:
- The debounce over fake pw-dump snapshots: start, end, minimum session, flapping, two apps,
  shepetal's own streams, device change, and tuned thresholds.
- Folder and file permissions.
- The recorder and whisper-cli arguments, and whisper output parsing.
- Transcript formatting.
- One whole meeting against fake `pw-dump`, `pw-record` and `whisper-cli`, run in a child copy
  of the test binary so it can set its own PATH.
- On Linux only: the recorder gets SIGINT when the thread that started it ends.

## Hand test (Ubuntu 24.04 desktop, GNOME)

Prerequisites: steps 1 to 3 of the manual test in docs/linux.md, plus `whisper-cli` on PATH
and `ggml-large-v3-turbo-q5_0.bin` in `~/.local/share/shepetal/`. Use headphones for steps 2
to 5 (see the known gaps).

1. `./target/release/shepetal daemon`. It must print `meeting detection on, Thresholds { poll: 2000, ... }`.
   If whisper-cli or the model is missing, it must also print the
   `meetings are recorded but not transcribed` line.
2. Join a Zoom test call (https://zoom.us/test) or a Google Meet in Firefox. Within about 8 s,
   the daemon must print `meeting (Zoom) recording to ~/.local/share/shepetal/meetings/<ms>,
   system audio Some("<sink>.monitor")`.
3. While it records, run `./target/release/shepetal probe`. It must list the call app as a mic
   user. It must not list `shepetal` or `pw-record`. If it does, the `-P application.name`
   rename does not work (docs/linux.md, known gaps).
4. Talk for about a minute while the other side talks too. Mute yourself in the call for 20 s,
   then unmute. The recording must go on: no `meeting ended` line.
5. Leave the call. About 4 to 6 s later (15 s after the start at the earliest) the daemon must
   print `meeting ended, transcribing ...`, then `meeting transcript .../transcript.md`.
6. Check the folder:
   - `ls -la ~/.local/share/shepetal/meetings/ ~/.local/share/shepetal/meetings/<ms>/`: both
     dirs are `drwx------`, and `Me.wav`, `Others.wav` and `transcript.md` are `-rw-------`.
   - `pw-play Me.wav` plays your voice and `pw-play Others.wav` plays the other side.
   - `transcript.md` has your words as `Me` and theirs as `Others`, with plausible times.
7. Join a call and plug in or switch to a Bluetooth headset during it. The recording must not
   end, and `Others.wav` must keep the other side after the switch.
8. During a call, `kill -9` the daemon. `pgrep -a pw-record` must show no shepetal recorder
   about a second later, and both WAVs must play up to the kill.
9. With Zoom and a Meet tab both in a call, leave Zoom. The recording must go on until the Meet
   call ends too, and the header must name both apps.

## Known gaps

- 🤫 has no meeting state yet. While a meeting records, the daemon's stderr line is the only
  sign of it. Section 7 asks for a clear recording indicator.
- No live transcript. The final pass runs only after the call (section 7 asks for streaming
  ASR per channel).
- Others is one speaker. The system channel is not diarized yet, and calendar names are not used.
- There is no summary yet. The non-LLM summarizer (`summarize/`) reads `Speaker: text` lines,
  so the `[hh:mm:ss] ` prefix must be stripped first.
- Others.wav follows the system default sink. If the call app sends audio to a device other
  than the default, Others.wav is silent. Linking to the call app's output stream would fix this.
- Without headphones, Me.wav also picks up the other side from the speakers, because
  pw-record gets the raw mic without echo cancellation. Their words then show up under Me too.
- An app that closes its mic stream while muted ends the recording after `reacquire`. Step 4
  checks this. Raise `reacquire` if it happens.
- There is no detection card (a prompt with a 20 s timeout), no wake holdoff, and no re-stop
  suppression. Recording starts without asking, as rule 7 says.
- The daemon records meetings only when dictation can start too (fn keyboard and model
  present).
- Ctrl+C or SIGKILL on the daemon keeps the audio but writes no transcript.
- Detection polls `pw-dump`. `pw-dump --monitor` or a registry listener would react sooner.
- Transcription speed on a long meeting on CPU (Whisper turbo) is not measured.
