# Meeting recording on Linux

`shepetal daemon` detects meetings on its own (goal rule 7). It records one only after you click
Record on a Record? prompt, or always with auto-record on (see Settings). The code is in
`linux/src/meeting_rec.rs`, and the pw-dump parsing it uses is in `linux/src/meeting.rs`.

## What it does

1. Every 2 s it runs `pw-dump` and reads /proc, and lists every other app that is using the mic
   or the camera. There is no list of meeting apps and no window or tab matching: any app on
   the mic or the camera is a possible meeting.
   - Mic: running `Stream/Input/Audio` nodes that are not on a sink monitor.
   - Camera: a running PipeWire camera (`Video/Source`, or `media.role` Camera) and the nodes
     linked to it. When PipeWire shows none, the processes that have a `/dev/video*` open
     (from `/proc/<pid>/fd`), which is how Zoom and most browsers use a camera.
   - shepetal's own processes never count: the daemon and its children (the dictation recorder,
     Me.wav and Others.wav), by pid. A pipewire-pulse stream (parecord) carries its pid on the
     node, and a native one (pw-record) on its Client object. Names are never used for this, so
     another app called shepetal or pw-record still counts.
   - It needs no permission and shows no prompt for one. It never opens the camera.
   If `pw-dump` is missing, or both `pw-record` and `parecord` are, the daemon says so at startup
   and records no meetings.
2. Once another app has used the mic or the camera for the start grace, it asks first. A desktop
   notification, "Record this meeting?", shows one Record button. Its text names the apps and
   what they use, for example "Zoom is using the microphone and camera.", or "An app is using
   the camera." when nothing names the app. Only app names are shown and logged, never a window
   title, tab or URL. It is sent through
   org.freedesktop.Notifications with `notify-send --action=record=Record`, which waits and
   prints `record` on a click.
   - Only a click on Record starts the recording. The click is seen at the next poll, so up to
     2 s later.
   - Dismissed, or Record not clicked within 20 s (`prompt`): nothing is recorded for that
     meeting, and it does not ask again until the mic and the camera have both been free for the
     end thresholds and are used again. An unanswered prompt is withdrawn
     (notify-send gets SIGINT and closes it).
   - If the call ends first, the prompt is withdrawn too.
   - With auto-record on (`{"meetings": {"auto_record": true}}` in config.json) it records
     right away, with no prompt.
   - Without `notify-send` (package libnotify-bin) and without auto-record, the daemon says so
     at startup and records no meetings.
3. On Record (or right away with auto-record), it creates
   `$XDG_DATA_HOME/shepetal/meetings/<unix-ms>/` (default `~/.local/share/...`) and records two
   16 kHz mono WAVs there:
   - `Me.wav`: the default mic.
   - `Others.wav`: the default sink's monitor, which is what you hear.
   It uses `pw-record`, and `parecord` when pw-record is missing. For Others.wav,
   `pw-record -P '{ stream.capture.sink = true }'` lets WirePlumber link it to the default
   sink's monitor and move it when the default sink changes. `parecord` uses
   `--device=@DEFAULT_MONITOR@`.
4. When no other app uses the mic or the camera any more, it waits out the end thresholds, stops both
   recorders with SIGINT (so the WAV header is written) and starts transcribing on another
   thread. Detection goes on meanwhile.
5. It runs `whisper-cli` on each file, keeping the segment times, and writes `transcript.md` next
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

Nothing leaves the machine.

## Settings

"Always record automatically" is off by default. Turn it on in the daemon's settings file,
`$XDG_CONFIG_HOME/shepetal/config.json` (else `~/.config/shepetal/config.json`), next to the
shortcuts (docs/linux-shortcuts.md):

```json
{"meetings": {"auto_record": true}}
```

- Then every detected meeting records with no Record? prompt.
- Missing, or `false`: ask first.
- A typo in `meetings`, a value that is not `true` or `false`, or broken JSON stops the daemon
  at startup with an error that names the file. It never falls back to recording silently.

The detection and prompt thresholds are a tuning knob in `SHEPETAL_MEETING_THRESHOLDS`
(see Thresholds).

## Retention

Meeting audio follows the same retention as dictation. On Linux that means every recording is
kept: the daemon has no retention setting yet (docs/linux.md, known gaps). The 24 h option for
dictation in #67 must also cover `meetings/` when it lands (#141).

## Thresholds

These are the values from docs/re/meetings.md (sections 2.3 and 2.4), the same as the Mac's
`MeetingDetector`. Override them in seconds with `SHEPETAL_MEETING_THRESHOLDS`, for example
`SHEPETAL_MEETING_THRESHOLDS="reacquire=8,start_after=3"`. A bad value stops the daemon with
an error.

| Name | Default | Meaning |
| --- | --- | --- |
| `poll` | 2 | Seconds between `pw-dump` reads |
| `start_after` | 5 | How long another app must use the mic or the camera before the Record? prompt (or, with auto-record, the recording). A miss starts the count again |
| `min_session` | 15 | No end in the first 15 s of a recording |
| `end_with_evidence` | 3 | Wait after the last app lets go of the mic and the camera (bound silence) |
| `reacquire` | 4 | If the mic or the camera is used again within this time, it is the same meeting. The end waits for the longer of this and `end_with_evidence` |
| `device_change` | 10 | A change of the default mic or speakers holds off an end this long |
| `prompt` | 20 | An unanswered Record? prompt is withdrawn after this long, and nothing is recorded (docs/re/meetings.md: the card's 20 s timeout) |

On Linux the mic and camera users are the only evidence, so every end is the bound kind. The 30 s unbound
silence never applies.

## Speech-to-text

The final pass is Whisper on the whole files (docs/re/meetings.md section 7). It uses the
dictation model when that is Whisper (Vulkan machines). On every other machine it uses
`~/.local/share/shepetal/ggml-large-v3-turbo-q5_0.bin`. When `whisper-cli` or that model is
missing, the daemon says so at startup. Meetings are still recorded, and the transcript lists
the error.

## Security

- Nothing records without a click on Record, unless auto-record is on.
  With Do Not Disturb on, GNOME shows no banner. The meeting then records only if Record is
  clicked in the notification list within 20 s.
- The `meetings` directory and each meeting folder are 0700. `Me.wav`, `Others.wav` and
  `transcript.md` are 0600 and created with `O_CREAT|O_EXCL`, so an existing folder or file
  (or a planted symlink) is never reused or overwritten.
- A `meetings` directory that is a symlink or open to others is refused, and nothing is
  recorded. The audio lives under the data home, never `/tmp`. An empty or relative
  `XDG_DATA_HOME` is ignored, as for dictation.
- The recorders get SIGINT (`PR_SET_PDEATHSIG`) when the daemon exits, even by SIGKILL, so a
  dead daemon never leaves the mic recording. For dictation, that gap is still open (#45).

## Tests

`cargo test` in `linux/` runs `meeting::tests` and `meeting_rec::tests`:
- Who is on the mic and the camera, over pw-dump fixtures and a fake /proc: any app counts,
  idle streams, sink monitors, playback and screencasts do not, a running camera with no named
  user counts unnamed, `/dev/video*` holders are the fallback, and shepetal's own processes are
  told apart by pid. `fixtures/pw-dump-own-recorders.json` is captured from real PipeWire 1.0.5
  (Ubuntu 24.04) running shepetal's pw-record and parecord.
- The debounce over fake pw-dump snapshots: start (on the mic, or on the camera alone), end,
  a new meeting after the end, minimum session, flapping, mic and camera together, shepetal's
  own streams, device change, and tuned thresholds.
- Folder and file permissions.
- The recorder and whisper-cli arguments, and whisper output parsing.
- Transcript formatting.
- The `notify-send` arguments, the app names and "An app", the 20 s default, and that only `"auto_record": true` turns
  auto-record on: a missing file, other features' keys, and `false` ask first, and a typo is an
  error.
- Whole meetings against fake `pw-dump`, `pw-record`, `whisper-cli` and `notify-send`, each run
  in a child copy of the test binary so it can set its own PATH:
  - Record clicked: recorded and transcribed.
  - The camera alone (a fake /proc where Zoom holds /dev/video0): offered, and recorded after
    the click.
  - Dismissed: no recorder runs and no folder is made, and it is not asked again.
  - No answer: the prompt is withdrawn at the timeout, and nothing is recorded.
  - Call ended first: the prompt is withdrawn, and nothing is recorded.
  - Auto-record on: recorded with no prompt.
- On Linux only: the recorder gets SIGINT when the thread that started it ends.

## Hand test (Ubuntu 24.04 desktop, GNOME)

Prerequisites: steps 1 to 3 of the manual test in docs/linux.md, plus `whisper-cli` on PATH,
`ggml-large-v3-turbo-q5_0.bin` in `~/.local/share/shepetal/` and `notify-send` (libnotify-bin).
Do Not Disturb off. Use headphones for steps 2 to 5 (see the known gaps). In steps 7 to 9,
click Record on the prompt.

1. `./target/release/shepetal daemon`. It must print
   `meeting detection on, asking before each recording, Thresholds { poll: 2000, ... prompt: 20000 }`.
   If whisper-cli or the model is missing, it must also print the
   `meetings are recorded but not transcribed` line.
2. Join a Zoom test call (https://zoom.us/test) or a Google Meet in Firefox. Within about 8 s:
   - A notification "Record this meeting?" with a Record button must show, naming the app as
     `probe` lists it, and the daemon must print
     `meeting detected (<app> on the microphone), asking: Record this meeting?` (or `on the
     microphone and camera` with video on). No window or tab title may show up in either.
   - `ls ~/.local/share/shepetal/meetings/` shows no new folder yet, and `pgrep -a pw-record`
     shows nothing.
   - Click Record. Within about 2 s the daemon must print `meeting (<app> on the microphone)
     recording to ~/.local/share/shepetal/meetings/<ms>, system audio Some("<sink>.monitor")`.
3. While it records, run `./target/release/shepetal probe`. It must list the call app as a mic
   user. The daemon's recorders are not children of `probe`, so `probe` lists them as
   `"shepetal"` with their pids: `pgrep -a pw-record` must show the same pids. The daemon
   itself never counts them.
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
   call ends too, and the header must name both apps. Then, in a call with video on, mute the
   mic in the call app: the recording must go on while the camera is on.
10. Join a call and close the notification without clicking Record. The daemon must print
    `the Record? prompt was dismissed`. For the rest of the call: no new folder in `meetings/`,
    no `pw-record` in `pgrep -a pw-record`, and no second prompt.
11. Join a call and leave the notification alone. About 20 s later it must disappear, from the
    screen and from the notification list, and the daemon must print
    `Record was not clicked within 20 s`. Nothing is recorded. If the notification stays, the
    SIGINT does not close it on this notify-send version (see the known gaps).
12. Join a call and leave it within 10 s, before clicking. When the daemon prints
    `meeting ended before Record was clicked`, the notification must disappear.
13. With nothing on the mic, run `ffplay -f v4l2 /dev/video0` (package ffmpeg), which opens
    the camera itself. `probe` must list `cam user:  "ffplay"`, and within about 8 s the
    notification must say `ffplay is using the camera.` Close it, then close ffplay. Do the same
    with GNOME Snapshot (Camera), which goes through PipeWire. No step may ask for a permission.
14. Put `{"meetings": {"auto_record": true}}` in `~/.config/shepetal/config.json` and restart
    the daemon. The startup line must say `recording every meeting`. Join a call: it must
    record within about 8 s with no notification. With `"auto_record": "yes"` instead, the
    daemon must stop at startup with `...config.json: meetings.auto_record: expected true or
    false`. Remove the key afterwards.

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
- Any app on the mic or the camera is offered as a meeting, also a voice recorder, another
  dictation app or a camera app. That is the rule (Pavel, 2026-10-21), not a bug.
- While PipeWire serves a camera, its own process holds `/dev/video*`. PipeWire's answer wins
  then, but in the few seconds after the last app stops, before WirePlumber suspends the camera,
  the `/proc` fallback still sees PipeWire on it, and the end comes that much later.
- The `/proc` fallback sees only the user's own processes, so a camera held by another user's
  process is not seen.
- The Record? prompt is a plain desktop notification, not a card in 🤫 (docs/re/meetings.md
  draws a card in its own window).
- The call before the click is not recorded, and a click is seen up to 2 s late.
- notify-send older than libnotify 0.7.10 (Ubuntu 22.04 has 0.7.9) has no `--action`. The
  prompt then fails, the daemon prints `notify-send failed`, and nothing is recorded. Turn on
  auto-record, or upgrade.
- The settings file is config.json (shortcuts, meetings), but the mic ranking reads
  config.toml (docs/linux-mic.md). Tracked in #144.
- That SIGINT makes notify-send close the notification is from libnotify's source, not tested
  on hardware. Step 11 checks it.
- There is no wake holdoff and no re-stop suppression.
- The daemon records meetings only when dictation can start too (fn keyboard and model
  present).
- Ctrl+C or SIGKILL on the daemon keeps the audio but writes no transcript.
- Detection polls `pw-dump`. `pw-dump --monitor` or a registry listener would react sooner.
- Transcription speed on a long meeting on CPU (Whisper turbo) is not measured.
