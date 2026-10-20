# Shepetal for iPhone

On-device dictation in any app, through a custom keyboard. No server, no network: speech is transcribed on the iPhone with [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT v3, CoreML).

## Architecture

iOS does not give keyboard extensions the microphone, and caps their memory (about 48 MB, undocumented). So the work is split across two processes:

| Target | Role |
|---|---|
| `Shepetal` (app) | Owns the mic and the speech model. Records with `AVAudioEngine` under the `audio` background mode so it keeps listening after the user goes back to their app, then transcribes with FluidAudio. |
| `ShepetalKeyboard` (keyboard extension) | A mic button, globe and delete. No audio, no model. Inserts the result with `textDocumentProxy.insertText`. |
| `ShepetalSessionCore` (framework) | The handoff state machine (`Handoff`) and the App Group transport (`SharedHandoff`), shared by both. |
| `ShepetalSessionCoreTests` | Unit tests for the state machine. |

Handoff, through the App Group `group.io.backant.shepetal` (shared `UserDefaults` holds the state, Darwin notifications are the doorbell):

```
keyboard: request(id)  ──open shepetal://dictate?id=──▶  app: startRecording(id)       idle → requested → recording
user goes back with the iOS back control, taps the mic again
keyboard: post "stop"  ─────────────────────────────▶  app: finishRecording(id)      → transcribing
                                                        app: deliver(id, text), post "ready"  → ready
keyboard: consume(id) → insertText                                                    → inserted
```

Rules the tests enforce (`Tests/HandoffTests.swift`):
- The keyboard only inserts text for the session id it requested. A late result from an older session is rejected, and a result is inserted at most once.
- `requested`, `transcribing` and `ready` expire after `Handoff.timeout` (60 s) without progress. `recording` never expires; the user decides when to stop.

Opening the app from the keyboard uses the responder chain to reach `UIApplication.open`. Apple has no supported API for this (`NSExtensionContext.open` is not available to keyboards), so it is the most fragile part and may break with an iOS update.

## Build and test

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The `.xcodeproj` is generated and not committed.

```sh
cd ios
xcodegen generate
xcodebuild -scheme Shepetal -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build test
```

The speech model (several hundred MB) downloads from Hugging Face into the app's Application Support folder on first launch. Model weights are never committed.

## Manual test on a real iPhone

The simulator has no usable mic path for this flow, so the end-to-end test runs on a device.

1. Open `Shepetal.xcodeproj`, set your team on the `Shepetal` and `ShepetalKeyboard` targets, and make sure both have the App Group `group.io.backant.shepetal` (change the id in `project.yml` and `Core/Handoff.swift` if your team cannot register it).
2. Run `Shepetal` on the iPhone. Wait for "Ready" (the first launch downloads the model).
3. Settings > General > Keyboard > Keyboards > Add New Keyboard > Shepetal. Tap Shepetal and turn on **Allow Full Access** (needed for the shared App Group container; the keyboard makes no network calls).
4. Open Notes, switch to the Shepetal keyboard with the globe key, tap the mic.
5. Shepetal opens and asks for the microphone the first time. Allow it. The status reads "Listening".
6. Go back to Notes with the back control in the top-left corner of the status bar. Speak.
7. Tap the mic on the keyboard. The text appears in the note.

Checks: with Full Access off, the keyboard asks you to turn it on. Tap the mic, wait more than 60 s before going back, then confirm nothing is inserted. Tap the mic twice in a row (two requests) and confirm only the second session's text is inserted.

## Not done yet

- Keeping the session open across several dictations without bouncing to the app (Wispr keeps the mic on for 5 minutes).
- Live Activity and `AudioRecordingIntent` (Action Button, Control Center, Shortcuts).
- Text cleanup, personal dictionary, history of late results.
- A real device run. Only the simulator build and unit tests are verified.
