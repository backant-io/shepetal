# shepetal-meeting

Meeting detection and capture for macOS, as a standalone Swift package.

- `MeetingCore`: pure Swift, no Apple frameworks (builds on Linux). `MeetingDetector` turns
  snapshots (apps holding the mic, browser window titles, current calendar event, default audio
  devices, a wake marker) into debounced `started(app:)` / `ended(app:)` events. Defaults: mic
  held ≥ 5 s starts a meeting; a native app's release ends it after 4 s, a release with the
  meeting tab or window still open after 30 s. shepetal's own dictation never counts.
- `MeetingMac`: probes and capture. Mic holders come from Core Audio
  (`kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput`, macOS 14.4+).
  Window titles are read only with Screen Recording access, the calendar event (EventKit) only with
  Calendar full access, so neither prompts. Default devices and a wake marker
  (`kern.waketime` + a `kAudioHardwarePropertyServiceRestarted` listener) need no permission.
  `MeetingCapture` records the mic to `Me.wav` and system audio (process tap + private aggregate
  device) to `Others.wav`, in an owner-only directory (0700, files 0600).
- `shepetal-meeting`: CLI with `probe`, `watch` and `record`.

Known apps: Zoom, Microsoft Teams, Slack (huddle window only), FaceTime, Webex, Discord by bundle ID;
Google Meet, Teams web and Zoom web in Chrome, Safari, Arc, Firefox and Edge by window title.
During a calendar event (from 5 min before its start to 5 min after its end, all-day events
excluded), any other app holding the mic also counts.

Thresholds follow `docs/re/meetings.md` (all tunable `MeetingDetector` properties): start after a
5 s grace (`startAfter`); no start within 10 s of wake or a Core Audio restart (`holdoff`, applied
when the snapshot's `wakeMarker` changes); no end in the first 15 s (`minSession`); a bound session
ends 3 s after mic release (`endWithEvidence`), an unbound one after 30 s (`endWithoutEvidence`);
the mic coming back within 4 s is the same meeting (`reacquire`, which also clamps the 3 s to 4 s);
and a change of default devices suppresses ends for 10 s (`deviceChangeGrace`). Bound means nothing
still proves the meeting: a native app let go of the mic, or a browser, Slack or calendar meeting's
tab, huddle window or event is gone as well. This is decided per meeting, so one app's evidence
never shortens another's wait. A running meeting stays on while the process that held the mic
still holds it, so switching to another browser tab does not end a Meet call. Native apps count on
mic hold alone, browsers only with a Meet/Teams/Zoom-web tab, Slack only with a huddle window.
Bundle IDs match case-insensitively (FaceTime reports `com.apple.facetime`, Safari's mic is held by
`com.apple.WebKit.GPU`).

## Build and test

```sh
cd meeting
swift build
swift test
# Linux (MeetingCore only):
docker run --rm -v "$PWD":/w -w /w swift:6.2 swift test
```

## Manual test (Pavel)

1. `cd meeting && swift build`
2. `.build/debug/shepetal-meeting probe` with nothing running prints
   `no process is using the mic`. This needs no permission. If your terminal app has Calendar
   access, `calendar event now:` names the event in progress (or starting within 5 min); otherwise
   it prints `none (or no Calendar access)`. The CLI never asks for Calendar access.
3. Start `.build/debug/shepetal-meeting watch` (faster: `START_AFTER=2 END_AFTER=3 .build/debug/shepetal-meeting watch`).
4. Join a Zoom call (or a test call at https://zoom.us/test). After ~5 s `watch` prints
   `started(app: "Zoom")`. Leave the call: ~4 s later it prints `ended(app: "Zoom")`.
   Switching your default mic or output (e.g. to AirPods) during the call must not end it.
5. Browser meetings need window titles, which macOS only exposes with Screen Recording
   permission: System Settings > Privacy & Security > Screen & System Audio Recording, enable
   your terminal, restart it. Then join a Google Meet in Chrome: `watch` prints
   `started(app: "Google Meet (Chrome)")`. Switch to another tab for a minute and back: no event.
   Close the Meet tab: ~4 s later `ended`. Without the permission browser meetings are not detected.
6. Dictate with shepetal while `watch` runs: no event must appear.
7. Calendar: with Calendar access for your terminal, start any mic app that is not a known
   meeting app (e.g. QuickTime > New Audio Recording) during a calendar event. `watch` prints
   `started(app: "QuickTime Player: <event title>")` after ~5 s.
8. Capture: `.build/debug/shepetal-meeting record 15` during a call. macOS asks for microphone and
   "System Audio Recording Only" access for your terminal on first run; allow both, then rerun.
   It prints `saved ~/Library/Application Support/shepetal/meetings/<time>/Me.wav and Others.wav`
   (exit 1 with the reason if nothing was written). Check that `Me.wav` holds your voice,
   `Others.wav` the other participants, and that `ls -la` shows `drwx------` and `-rw-------`.

## Known limits

- Chrome reports only the active tab's title; a Meet call that starts in a background tab is
  missed (one that started in the front tab survives tab switches). The flip side: a browser
  meeting only ends once the browser lets go of the mic, even if another site took it over.
- Calendar needs Calendar full access for the process. The CLI only gets it if your terminal app
  has it; the shepetal app will ask for it itself.
- `record` writes files from the real-time audio thread (sketch). It assumes the aggregate
  device delivers the mic buffer first and the tap buffer last.
