# shepetal-meeting

Meeting detection and capture for macOS, as a standalone Swift package.

- `MeetingCore`: pure Swift, no Apple frameworks (builds on Linux). `MeetingDetector` turns
  snapshots (processes capturing the mic, whether a camera runs, default audio devices, a wake
  marker) into debounced `started(app:)` / `ended(app:)` events. Pavel's rule (2026-10-21): any
  other app using the mic or a camera for 5 s is a possible meeting, and it ends 4 s after both are
  free. There are no app lists and no window titles. Shepetal's own use never counts: it is
  excluded by its pid and bundle ID, never by name.
- `MeetingMac`: probes and capture. Mic users come from Core Audio process objects
  (`kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput`, PID and
  bundle ID, macOS 14.4+), each with its executable and the one of the process macOS holds
  responsible for it. Camera use comes from CoreMediaIO
  (`kCMIODevicePropertyDeviceIsRunningSomewhere` on every camera), which reads no frames. Default
  devices and a wake marker (`kern.waketime` + a `kAudioHardwarePropertyServiceRestarted`
  listener) complete the snapshot. None of it needs a permission or shows a prompt: no
  Microphone, Camera or Screen Recording access.
  `MeetingCapture` records the mic to `Me.wav` and system audio (process tap + private aggregate
  device) to `Others.wav`, in an owner-only directory (0700, files 0600).
- `shepetal-meeting`: CLI with `probe`, `watch` and `record`.

The card names the app: the outermost `.app` bundle in the mic user's path, so a helper is named
after its app (`Google Chrome Helper` is "Google Chrome", `us.zoom.CptHost` is "zoom.us"). A
process outside any app (Safari's `com.apple.WebKit.GPU`) is named after the app responsible for
it ("Safari"). Without an app it is "Microphone", and a camera alone is "Camera", since macOS does
not say which process runs a camera. Browser meetings (Meet, Teams or Zoom on the web) are found
the same way, from the browser's mic or camera use, with no tab titles.

Thresholds follow `docs/re/meetings.md` (all tunable `MeetingDetector` properties): start after a
5 s grace (`startAfter`); no start within 10 s of wake or a Core Audio restart (`holdoff`, applied
when the snapshot's `wakeMarker` changes); no end in the first 15 s (`minSession`); end 4 s after
the mic and the camera are both free, so use that comes back sooner is the same meeting
(`endAfter`); and a change of default devices suppresses ends for 10 s (`deviceChangeGrace`).

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
   `no process is using the mic`, `camera in use: no` and `meeting now: none`. This needs no
   permission and shows no prompt.
3. Start `.build/debug/shepetal-meeting watch` (faster: `START_AFTER=2 END_AFTER=3 .build/debug/shepetal-meeting watch`).
4. Join a Zoom call (or a test call at https://zoom.us/test). After ~5 s `watch` prints
   `started(app: "zoom.us")`. Leave the call: ~4 s later it prints `ended(app: "zoom.us")`.
   Switching your default mic or output (e.g. to AirPods) during the call must not end it.
5. Join a Google Meet in Chrome: `watch` prints `started(app: "Google Chrome")`, with no Screen
   Recording access. Close the tab: ~4 s later `ended`.
6. Open Photo Booth (camera only): `started(app: "Camera")`. Quit it: ~4 s later `ended`
   (15 s at the earliest).
7. Dictate with shepetal while `watch` runs: no event must appear.
8. Capture: `.build/debug/shepetal-meeting record 15` during a call. macOS asks for microphone and
   "System Audio Recording Only" access for your terminal on first run; allow both, then rerun.
   It prints `saved ~/Library/Application Support/shepetal/meetings/<time>/Me.wav and Others.wav`
   (exit 1 with the reason if nothing was written). Check that `Me.wav` holds your voice,
   `Others.wav` the other participants, and that `ls -la` shows `drwx------` and `-rw-------`.

## Known limits

- Any mic or camera use counts, so a voice memo, a dictation app or a camera check is offered as a
  meeting too. Nothing records until Record is clicked.
- The card names the first app that used the mic; it is not renamed when another app takes over.
- `record` writes files from the real-time audio thread (sketch). It assumes the aggregate
  device delivers the mic buffer first and the tap buffer last.
