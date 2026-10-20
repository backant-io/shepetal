# shepetal-meeting

Meeting detection and capture for macOS, as a standalone Swift package.

- `MeetingCore`: pure Swift, no Apple frameworks (builds on Linux). `MeetingDetector` turns
  snapshots (apps holding the mic, browser window titles, current calendar event) into
  debounced `started(app:)` / `ended(app:)` events. Defaults: mic held ≥ 5 s starts a meeting,
  released ≥ 10 s ends it. shepetal's own dictation never counts.
- `MeetingMac`: Core Audio probes (`kAudioHardwarePropertyProcessObjectList` +
  `kAudioProcessPropertyIsRunningInput`, macOS 14.4+) and `MeetingCapture`, which records the
  mic to `Me.wav` and system audio (process tap + private aggregate device) to `Others.wav`.
- `shepetal-meeting`: CLI with `probe`, `watch` and `record`.

Known apps: Zoom, Microsoft Teams, Slack (huddles), FaceTime, Webex, Discord by bundle ID;
Google Meet, Teams web and Zoom web in Chrome, Safari, Arc, Firefox and Edge by window title.
During a calendar event, any other app holding the mic also counts.

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
   `no process is using the mic`. This needs no permission.
3. Start `.build/debug/shepetal-meeting watch` (faster: `START_AFTER=2 END_AFTER=3 .build/debug/shepetal-meeting watch`).
4. Join a Zoom call (or a test call at https://zoom.us/test). After ~5 s `watch` prints
   `started(app: "Zoom")`. Leave the call: ~10 s later it prints `ended(app: "Zoom")`.
5. Browser meetings need window titles, which macOS only exposes with Screen Recording
   permission: System Settings > Privacy & Security > Screen & System Audio Recording, enable
   your terminal, restart it. Then join a Google Meet in Chrome: `watch` prints
   `started(app: "Google Meet (Chrome)")`. Without the permission browser meetings are not detected.
6. Dictate with shepetal while `watch` runs: no event must appear.
7. Capture: `.build/debug/shepetal-meeting record 15` during a call. macOS asks for microphone and
   "System Audio Recording Only" access for your terminal on first run; allow both, then rerun.
   Check that `Me.wav` holds your voice and `Others.wav` the other participants.

## Known limits

- Chrome reports only the active tab's title; a Meet call in a background tab is missed.
- `record` writes files from the real-time audio thread (sketch). It assumes the aggregate
  device delivers the mic buffer first and the tap buffer last.
