# Wispr Flow on other platforms, and what shepetal needs for iPhone and Linux

Status: research notes from the 2026-10-20 sprint (17:28 to 17:58). This file records behavior only. It contains no Wispr code, strings or assets. Facts are tagged by source type:
**[W]** Wispr's own help center, App Store page or changelog. **[A]** Apple developer docs. **[B]** desktop bundle (read-only, `/Users/sorcecoder/shepetal-re/asar`). **[3P]** third-party docs, READMEs or reviews. **[Inference]** our reading of the evidence, not confirmed.

---

## 1. iPhone architecture (Wispr), with evidence

### 1.1 Two pieces: a containing app and a custom keyboard

- The app ships a third-party keyboard that the user adds under Settings > General > Keyboard > Keyboards. The keyboard only shows up in Settings after the app has been opened once and onboarding is done. [W] [setup article](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- Setup needs **Allow Full Access**. Wispr says Full Access is required for transcription and for working across apps. Without it, the keyboard stays installed but cannot transcribe. [W] same article; [search summary of the turn-off article](https://docs.wisprflow.ai/articles/7148015379-turn-off-or-remove-the-flow-keyboard-on-iphone)
- The **microphone permission belongs to the containing app**, not to the keyboard. The first mic tap inside the app triggers the iOS prompt, and the help text says a keyboard cannot show that prompt itself. The keyboard runs its checks in a fixed order: weekly word cap, then Full Access, then mic permission. [W] setup article
- Requirements: iOS 18.3 or later, 191 MB download, also runs on visionOS 2.3+. [W] [App Store listing](https://apps.apple.com/us/app/wispr-flow-ai-voice-keyboard/id6497229487)

### 1.2 How recording works: the "Flow Session" in the host app

Apple does not let a keyboard extension use the microphone (section 2), so Wispr records in the **containing app** and keeps that app alive in the background:

1. In another app, the user taps the start control on the Flow keyboard.
2. The keyboard opens the Flow app. The app starts the mic and begins a **Flow Session**, then sends the user back to the app they came from. [W] setup article; [9to5Mac review via search](https://9to5mac.com/?p=1008112)
3. Wispr says automatic return is not reliable: it depends on the target app, the account and the iOS version. Going back through the iOS back control in the status bar keeps the user's place, but a return that relaunches the target app may not. [W] setup article
4. A **10-second handoff window** applies. If the keyboard comes back and is ready within 10 seconds, recording carries on. After 10 seconds the pending switch, its return target and the automatic dictation start all expire. A stuck stop clears after 3 seconds. [W] setup article
5. While the session is open the mic stays on, but audio is not processed until the user starts and stops a dictation from the keyboard, the Action Button or the app. This lets the user do many dictations in a row without bouncing to the app again. [W] [background-audio article](https://docs.wisprflow.ai/articles/8415579688-why-wispr-flow-doesn-t-pause-background-audio-on-iphone-ios), plus help-center search results
6. **Session timeout**: the idle session ends after **5 minutes** by default. The user can set it to end after each transcription, or never. (Older help text and the Wikipedia summary also list 15 minutes and 1 hour, so the option list has changed over time.) [W] background-audio article; [Wikipedia](https://en.wikipedia.org/wiki/Wispr_Flow)
7. A single dictation has a **fixed 5-minute cap** that the user cannot change. [W] background-audio article
8. Calls, Siri, audio interruptions and connecting or disconnecting a headset or Bluetooth device stop recording, and it does not resume on its own. [W] setup and background-audio articles
9. Flow records **alongside** other audio: it does not pause or duck music or podcasts, so speaker output can leak into the transcript. Ducking is listed as a customer request. [W] background-audio article. **[Inference]** This matches an `AVAudioSession` configured with the `mixWithOthers` option ([A] [mixWithOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers)), which a background recorder needs so it does not kill the user's music when the session starts.
10. Recording state is shown as a **Live Activity** on the Lock Screen and in the Dynamic Island (live timer since app version 1.62). [W] App Store version history; [notifications article](https://docs.wisprflow.ai/articles/9454889914-how-to-disable-wispr-flow-notifications-on-ios)

**[Inference] App process model**: the containing app has the `audio` background mode and keeps an active record session for the length of the Flow Session. This is the only public way for a third-party app to keep a mic open after the user leaves it. The "mic on but not processing" wording matches an audio engine that runs the whole time, with the app keeping only the frames between start and stop.

### 1.3 Handing text back to the keyboard (App Group / IPC)

Wispr does not document the IPC. The evidence:

- Full Access is what unlocks a **shared container** between a keyboard and its containing app, and it is also what unlocks network access ([A] section 2). Wispr says transcription does not work without Full Access. So the keyboard either reads the result from the shared container, calls the server itself, or both. [W] + [A]
- If the connection drops mid-dictation, Flow still inserts the text later. If a newer dictation has taken over the field, the late text goes to History instead. [W] setup article. **[Inference]** So the keyboard tracks a per-dictation ID and only inserts a result that matches the current field and dictation. Late results go to a shared history store.
- **[Inference] Most likely mechanism**: an App Group container (shared `UserDefaults` or files) for the payload, plus Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) for "start", "stop" and "result ready" pings between the two processes. Apple documents App Groups as allowing "interprocess communication (IPC) between those apps using Mach IPC, POSIX semaphores and shared memory" and as the way "to share data between an app extension ... and its host app". [A] [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups); [A] [Darwin notify center](https://developer.apple.com/documentation/corefoundation/cfnotificationcentergetdarwinnotifycenter())
- The keyboard inserts text through its text document proxy (`insertText`), which is the only way a keyboard can write into the host field. [A] [Custom Keyboard guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)

### 1.4 Features available on iOS

- Voice keyboard in any app; AI cleanup (punctuation, formatting, tone); personal dictionary; "whisper mode" for quiet speech; 100+ languages; Flow Notes that sync with desktop; history with one-tap retry for failed or interrupted dictations (v1.62). Free tier has a weekly word cap. [W] App Store listing
- Starting without the keyboard: **Action Button** (iPhone 15 Pro and later), six **Shortcuts/Siri** actions (for example quick dictation to clipboard, dictate a Flow Note, turn the session on or off), a **Control Center** toggle, a Lock Screen Flow Notes widget, and a Live Activity with Stop and Notes buttons. Shortcuts can only start dictation if Live Activities are enabled. [W] [shortcuts article](https://docs.wisprflow.ai/articles/1986921789-how-to-set-up-flow-shortcuts-for-iphone). **[Inference]** That Live Activity rule matches Apple's `AudioRecordingIntent` contract (section 2).
- Needs a network: offline, the keyboard shows a "no network" state instead of the dictation controls. [W] setup article
- Field types: secure fields, number pad, phone, decimal, email and numbers-and-punctuation fields switch to the system keyboard. URL and search fields stay on Flow. Some banking apps block third-party keyboards. iPad has no globe switcher for custom keyboards. [W] setup article

### 1.5 What the desktop bundle says about mobile [B]

A grep of the desktop bundle (`.webpack/main` and `.webpack/renderer`, read-only) found no keyboard-extension or App Group code. That is expected, since the iOS app is a separate native binary. What the bundle does show:
- Desktop nudges the user toward the phone apps (a hub sidebar call to action for iPhone and Android, plus analytics events for an iOS modal and a keyboard modal).
- An analytics event family for an iOS **voice-processing** setup and exposure. **[Inference]** This looks like an A/B test of Apple's voice-processing input (echo cancellation and noise suppression on the audio engine), which would also address the "music leaks into transcript" complaint.
- A flag for App Store subscribers, so the desktop billing UI handles plans bought through Apple's in-app purchase differently.
- Notes, shared notes, meetings and todos sync through server calls on sign-in and on a timer. So cross-device sync runs through the **server**, not peer to peer. Transcript history is per device: on Android the docs say history does not sync with desktop. [W] [Android changelog](https://roadmap.wisprflow.ai/changelog/wispr-flow-is-now-live-on-android-robotrocket)

---

## 2. iOS constraints, with Apple doc links

| Constraint | Apple source | What it means for us |
|---|---|---|
| Keyboards cannot use the mic: "Custom keyboards, like all app extensions in iOS 8.0, have no access to the device microphone, so dictation input is not possible." | [A] [App Extension Programming Guide: Custom Keyboard](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html) | Recording has to happen in the containing app. (The guide is archived. Apple has not published a newer rule that changes this, and every shipping voice keyboard, Wispr included, still bounces to its app.) |
| By default a keyboard "has no network access and cannot share a container with its containing app". `RequestsOpenAccess = YES` (Full Access) adds a shared container, network, `UIPasteboard` and audio playback. | [A] same guide; [A] [RequestsOpenAccess](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionattributes/requestsopenaccess) | shepetal needs Full Access **only for the shared container**, not for the network. We should say so in the onboarding text. |
| The keyboard can check at runtime whether it has Full Access. | [A] [UIInputViewController.hasFullAccess](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/hasfullaccess) | Show a "turn on Full Access" card in the keyboard when it is off. |
| Secure text fields and phone-pad fields always get the system keyboard. | [A] Custom Keyboard guide | Nothing to build; document it. |
| A host app can block all custom keyboards. | [A] Custom Keyboard guide (`application:shouldAllowExtensionPointIdentifier:`) | Some banking apps will never work; tell users to use the Shortcut-to-clipboard path there. |
| No API to list enabled keyboards or to switch to a given keyboard. A keyboard cannot select text or use the host's edit menu. | [A] Custom Keyboard guide | The keyboard cannot "auto-switch back" to the user's normal keyboard; it must show `advanceToNextInputMode` (globe). |
| `NSExtensionContext.open(_:)` is supported only by the **Today and iMessage** extension points on iOS. Keyboards are not on that list. | [A] [NSExtensionContext.open](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)) | There is **no supported way** for a keyboard to open its containing app. Shipping apps use an unofficial workaround: walking the responder chain to call `openURL`. Apple engineers on the forums say walking the responder chain for this is "not allowed" and is a compatibility risk. On iOS 18 the old `openURL:` selector logs a "BUG IN CLIENT OF UIKIT" warning and returns NO, so the workarounds moved to the newer `open(_:options:)` selector ([A forum] [thread 65621](https://developer.apple.com/forums/thread/65621), [thread 763568](https://developer.apple.com/forums/thread/763568)). Wispr's keyboard does open the app, so some variant still works on iOS 18.3+, but this is the **most fragile part of the design** and an App Review risk. |
| There is also **no public API to return the user to the previous app**. | No Apple API exists; Wispr itself says automatic return depends on the app, the account and the iOS version [W] | Rely on the iOS back control in the status bar; treat any automatic return as best effort. |
| Background audio: `UIBackgroundModes` with `audio` lets an app keep running in the background while it plays or records. | [A] [UIBackgroundModes](https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes) | This is what keeps the session alive after the bounce. |
| Recording cannot start from the background. Apple's error docs say the "cannot start recording" error "usually occurs when an app starts a mixable recording from the background and it isn't configured as an Inter-App Audio app" (Inter-App Audio is deprecated). | [A] [AVAudioSession.ErrorCode.cannotStartRecording](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartrecording) | This is **why the bounce exists**: the containing app must come to the foreground once to start the mic. After that, background audio keeps it running. `AudioRecordingIntent` (below) is the only sanctioned exception. |
| `mixWithOthers` lets our recording run alongside the Music app instead of interrupting it. | [A] [mixWithOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers) | Same trade-off Wispr has: no ducking, so speaker audio can leak in. Voice processing helps with this. |
| `AudioRecordingIntent` (iOS 18+): "you must start a Live Activity when you begin the audio recording and keep it active as long as you record audio. If you don't start a Live Activity, the audio recording stops." | [A] [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent) | This is the supported way to start recording from the Action Button, Control Center or Siri **without** the app coming to the foreground. Live Activity support is required. |
| App Groups: shared containers plus IPC via Mach IPC, POSIX semaphores and shared memory between an app and its extensions. | [A] [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups) | The channel for audio-free signalling and the text result. |
| Darwin notifications are system-wide pings with no payload. Delivery needs the receiver's run loop to be running. | [A] [CFNotificationCenterGetDarwinNotifyCenter](https://developer.apple.com/documentation/corefoundation/cfnotificationcentergetdarwinnotifycenter()) | Use them as a doorbell only. Put the payload in the App Group container. |
| **Keyboard memory cap**: Apple does **not document** a number. Secondary sources say **48 MB** for keyboards (vs 120 MB for share extensions), and going over it terminates the keyboard silently. | [3P] [React Native app-extension docs](https://reactnative.dev/docs/0.81/app-extensions); [3P] [Fleksy: limitations of iOS keyboards](https://fleksy.com/blog/limitations-of-custom-keyboards-on-ios). Apple forum [thread 85478](https://developer.apple.com/forums/thread/85478) shows keyboard view controllers piling up in memory in some host apps (WhatsApp), but gives no cap. | We found **no source for the ~70 MB figure** in the brief. Budget the keyboard at less than 30 MB and **never load a speech model in the keyboard**. Measure on a real device. |
| On-device speech: `SFSpeechRecognitionRequest.requiresOnDeviceRecognition` keeps audio on the device. The newer `SpeechAnalyzer` is iOS 26+. | [A] [requiresOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition); [A] [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) | This gives us a zero-download local option in addition to Whisper-family models in the containing app. |

---

## 3. Recommended shepetal iPhone architecture

Goal: fully local, no server, same user experience as Wispr's keyboard plus session.

**Processes**
1. **Containing app** (SwiftUI). It owns the mic, the speech model and any text cleanup.
   - `UIBackgroundModes: audio`. `AVAudioSession` set to `.playAndRecord` with `mixWithOthers`, plus an option for Apple voice processing (echo and noise reduction).
   - The **session** is an `AVAudioEngine` input tap that runs the whole time and writes into a ring buffer. Frames are kept only between "start" and "stop". The idle timeout defaults to 5 minutes, with "after each dictation" and "never" as options (same choices users already know from Wispr).
   - A Live Activity shows recording state. This is required anyway for `AudioRecordingIntent`.
   - Speech-to-text: a Whisper-family model run on device (Core ML / ANE build), with Apple `SpeechAnalyzer` (iOS 26+) or `SFSpeechRecognizer` with `requiresOnDeviceRecognition` as a no-download fallback. Model choice and benchmarks are another agent's area.
2. **Keyboard extension**. Thin: UI, App Group I/O and `textDocumentProxy.insertText`. **No model and no audio.** Memory target is under 30 MB.
   - `RequestsOpenAccess = YES`, used only for the App Group. The keyboard never opens a network connection. Being open source, we can point to the code. The onboarding text says: "Full Access lets the keyboard read the text the app transcribed. shepetal keyboard makes no network calls."
   - Checks `hasFullAccess` and shows a setup card when it is off.
3. **App Intents**. `AudioRecordingIntent` actions for the Action Button, Control Center (iOS 18 control) and Siri/Shortcuts: "start session", "dictate to clipboard", "dictate a note". These start the mic **without** the keyboard bounce.

**IPC (App Group `group.<team>.shepetal`)**
- Keyboard to app: write a command record `{id, cmd: start|stop|cancel, ts, hostBundleHint?}` to the shared container, then post a Darwin notification. Darwin notifications carry no payload, so they act only as the doorbell.
- App to keyboard: write `{id, state, text, ts}` and post a Darwin notification. The keyboard inserts the text only if `id` matches the dictation it started and the field is still active. Otherwise it leaves the text in shared history (the same race Wispr handles; see 1.3).
- Heartbeat: while a session is open the app updates a `sessionAlive` timestamp, so the keyboard knows whether it can start a dictation directly or has to bounce to the app first.

**Starting a session from the keyboard**
- If the session is alive, start recording at once (no bounce).
- If it is not alive, open `shepetal://session?return=1` using the same unofficial responder-chain URL open that shipping keyboards use. Flag this as an **App Review and iOS-update risk**. The app starts the session; the user returns with the iOS back control. Keep a 10-second "pending start" token so recording starts on its own when the keyboard comes back, which matches Wispr's behavior.
- Fallback if the URL open stops working: the keyboard shows "Open shepetal to start a session" and offers the Action Button or Control Center path.

**Out of scope for v1** (YAGNI): an LLM rewrite step on the phone (memory and battery cost, and it would run in the app, not the keyboard), cross-device sync, and iPad layout.

---

## 4. Android and Windows deltas (Wispr)

**Android** (early access since 2026-02-23)
- Not a keyboard. It shows a **floating bubble** over text fields and uses Android's system-level access to type. **[Inference]** This is an accessibility service plus overlay permission, since Google Play keeps asking users about Flow's permissions ([W] [Google Play permissions article](https://docs.wisprflow.ai/articles/1842649381-why-does-google-play-keep-asking-about-wispr-flow-permissions)). [W] [Android changelog](https://roadmap.wisprflow.ai/changelog/wispr-flow-is-now-live-on-android-robotrocket)
- Same core dictation engine as desktop: punctuation, lists, filler-word removal, self-corrections, 100+ languages. Subscription syncs across devices, but **transcript history stays separate** from desktop. Wispr says parity is still in progress. [W] same changelog
- At launch, press reported **no** custom dictionary, voice templates, per-app styles or context awareness on Android ([3P] [Mezha](https://mezha.ua/en/news/wispr-flow-on-android-308809/)). A later review says the dictionary and snippets sync on all four platforms ([3P] [Laxis](https://www.laxis.com/de/blog/wispr-flow/)). The current status is unclear.
- Android lets the mic run in a foreground service, and an accessibility service can insert text into any field. So Android does not need the iOS app bounce. A shepetal Android app could use the same model.

**Windows**
- Close to the Mac feature set (the same desktop app). A competitor review reports about 800 MB RAM at idle and target apps freezing during insertion ([3P] [Spokenly review](https://spokenly.app/blog/wispr-flow-review); a biased source). The BLE mic ring is early access on Mac and Windows only ([W] [system requirements](https://docs.wisprflow.ai/articles/1036674442-supported-devices-and-system-requirements)). Windows runs as a system-tray app and has no offline mode (the same is true of every Wispr platform) ([3P] [bossai](https://bossai.tech/blog/wispr-flow-for-windows), a competitor blog). Third-party comparisons say there is no iPad, Linux, Chromebook, VM or remote-desktop support ([3P] [Voicy](https://usevoicy.com/comparisons/wispr-flow-vs-windows-speech-recognition)). We found no official list of Mac-only features. The macOS-only items OpenWhispr mentions (Globe/Fn key, mouse-button hotkeys) are OS-level limits, not product choices.

**Linux**: Wispr has no Linux app. That is shepetal's opening.

---

## 5. Linux requirements and the recommended stack

A Linux dictation app does the same four jobs as on the Mac: hear a global hotkey (press **and** release, for push-to-talk), capture the mic, transcribe locally, and put the text into the focused window. X11 allows all four with no special permission. Wayland deliberately blocks global key snooping and synthetic input between clients, so each job needs a portal, a compositor-specific protocol, or root-equivalent device access.

### 5.1 Global hotkey

| Method | X11 | GNOME Wayland | KDE Wayland | wlroots (Sway, Hyprland) | Notes |
|---|---|---|---|---|---|
| X11 key grab (`XGrabKey`, libraries such as `rdev`, Electron/Tauri global shortcut) | yes | XWayland windows only | XWayland windows only | XWayland windows only | Does **not** work on Wayland: OpenWhispr says Electron global shortcuts fail there [3P] [OpenWhispr Linux](https://docs.openwhispr.com/platform/linux) |
| **xdg-desktop-portal GlobalShortcuts** (`CreateSession`, `BindShortcuts`; `Activated`/`Deactivated` signals with ms timestamps, so press and release) | n/a | GNOME **48+** (the portal backend landed in xdg-desktop-portal-gnome 48.rc) | Plasma (advertised in `kde.portal`; first version not pinned down) | Hyprland portal; others vary | The user approves the bindings in a desktop dialog and may bind only some of them. Works from Flatpak. [Spec](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html); [GNOME changelog via BLFS #21291](https://wiki.linuxfromscratch.org/blfs/ticket/21291); [GNOME issue #85](https://gitlab.gnome.org/GNOME/xdg-desktop-portal-gnome/-/issues/85) |
| Desktop's own custom shortcut that runs a CLI command (`app --toggle`, or a signal) | yes | yes (gsettings) | yes (kglobalaccel) | yes (config bind) | Toggle only: there is **no release event**, so no push-to-talk. Handy and nerd-dictation use this. OpenWhispr writes GNOME custom shortcuts itself and falls back to tap-to-talk on GNOME before 48. [3P] [Handy](https://github.com/cjpais/Handy); [3P] [nerd-dictation](https://github.com/ideasman42/nerd-dictation) |
| **evdev** (read `/dev/input/event*` directly) | yes | yes | yes | yes | Needs the user in the **`input` group** (log out and back in). That makes the app able to read every keystroke on the machine, the same power as a keylogger. Works with any compositor and gives real press/release. Flatpak only gets it with `--device=input` (Flatpak 1.15.6+) or `--device=all`. [Flatpak permissions](https://docs.flatpak.org/en/latest/sandbox-permissions.html) |

### 5.2 Text insertion

| Method | Works on | Cost |
|---|---|---|
| `xdotool type` / XTest | X11, plus XWayland windows | None on X11. Never reaches native Wayland windows. |
| `wtype` (Wayland virtual-keyboard protocol) | wlroots compositors (Sway, Hyprland, river) | Not supported on GNOME: Handy says `wtype` does not work on Ubuntu 26.04, and other projects map it to Sway and Hyprland only. [3P] [Handy](https://github.com/cjpais/Handy); [3P] [voicsh](https://lib.rs/crates/voicsh) |
| `ydotool` / `dotool` (kernel `/dev/uinput` virtual keyboard) | everything, including TTYs | Needs `ydotoold` running with write access to `/dev/uinput` (input group or a udev rule). Sends **keycodes**, so the result depends on the keyboard layout. It bypasses the compositor's permission model. [3P] [OpenWhispr](https://docs.openwhispr.com/platform/linux); [3P] [wdotool](https://github.com/cushycush/wdotool) |
| **RemoteDesktop portal** (`SelectDevices` keyboard, `Start` shows a consent dialog, `NotifyKeyboardKeysym`, or `ConnectToEIS` to get a libei socket in v2; `persist_mode=2` plus a single-use `restore_token` skips the dialog next time) | GNOME 45+, KDE 6.1+ (per voicsh's backend table) | The only **sanctioned** typing path on GNOME and KDE, and it works from Flatpak. Downsides: a consent dialog the first time, and a keysym-per-character typing speed. [Spec](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html); [3P] [voicsh](https://lib.rs/crates/voicsh); [3P] [WayType](https://www.nuget.org/packages/waytype) |
| **Clipboard + synthetic paste key** | everywhere a paste key can be sent | Layout-independent and fast for long text. Needs one of the methods above to press Ctrl+V. Terminals need Ctrl+Shift+V and some editors Shift+Insert (OpenWhispr keeps a per-app table). Save and restore the user's clipboard. On Wayland, setting the clipboard needs either a focused surface or a data-control protocol. |
| **Clipboard only** | everywhere | Last resort: "text copied, press Ctrl+V". OpenWhispr calls this its Wayland clipboard mode. |

### 5.3 Audio

- **Mic**: capture through PipeWire. Its PulseAudio compatibility layer means one code path (PulseAudio API or `pw-cat`/native PipeWire) covers PipeWire and old PulseAudio systems. nerd-dictation supports `parec`, `sox` and `pw-cat`. [3P] [nerd-dictation](https://github.com/ideasman42/nerd-dictation)
- **System audio** (meeting capture, if we ever do it): record the **monitor source of the default sink**. No dialog appears, which is easy but means the user gets no indicator. [3P] [OpenWhispr](https://docs.openwhispr.com/platform/linux)
- **Flatpak**: `--socket=pulseaudio` grants mic **and** playback (and `/dev/snd`), and Flatpak's own docs call this permission sensitive. There is no audio-only capture portal. [Flatpak permissions](https://docs.flatpak.org/en/latest/sandbox-permissions.html)

### 5.4 Tray / indicator

- Use **StatusNotifierItem** (D-Bus). KDE and most wlroots bars show it natively. Stock GNOME needs the AppIndicator extension (Ubuntu ships it on by default). So the tray must be **optional**, and the app must still be fully usable without it. Handy has `--no-tray` and `--start-hidden` for this. [3P] [Handy](https://github.com/cjpais/Handy)
- A floating recording overlay is risky on Linux. Handy turned its overlay off by default because it stole focus and broke pasting on X11, and it needs `gtk-layer-shell` on Wayland. **Lesson: any overlay must never take focus.** [3P] [Handy](https://github.com/cjpais/Handy)

### 5.5 Packaging

| Format | Pros | Cons for a dictation app |
|---|---|---|
| **.deb / .rpm** | No sandbox; can ship a udev rule for `/dev/uinput`; deps resolved by apt/dnf (Handy: use `apt install ./x.deb`, not `dpkg -i`) | One build per distro family; we maintain repos |
| **AppImage** | One file, no install, no sandbox | Needs FUSE 2 on newer distros; cannot install udev rules or a user service; Handy's AppImage forces X11 (0.9.6); OpenWhispr's AppImage loses browser sign-in |
| **Flatpak** | Flathub reach, auto-updates, sandbox users trust | Must go through portals: GlobalShortcuts plus RemoteDesktop work; evdev needs `--device=input`/`all`; ydotool needs a host socket hole (Speech Note asks users to grant the `ydotoold` socket). Flathub reviewers question `--device=all`. Large models must live in user data, not in the package (Speech Note: 1.2 GiB base, 48 MiB "tiny", 4 to 8 GiB GPU add-ons). [3P] [Speech Note](https://github.com/mkiol/dsnote) |

### 5.6 Recommended shepetal Linux stack

Keep it to one binary with **backends chosen at runtime**. Probe in this order and show the result in Settings ("Hotkey: portal. Typing: portal (KDE)."):

1. **Hotkey**: GlobalShortcuts portal (press/release, so push-to-talk works) → evdev if the user opted into the `input` group → X11 grab on X11 → CLI `shepetal toggle` for the user to bind (toggle mode only).
2. **Typing**: X11 → XTest. Wayland → RemoteDesktop portal with `persist_mode=2` (one consent, then silent) → `wtype` on wlroots → `ydotool` if its socket is there → clipboard only. Long text goes through clipboard plus paste key, with the user's clipboard restored afterwards.
3. **Audio**: PipeWire through the PulseAudio API; 16 kHz mono from the default source.
4. **Tray**: StatusNotifierItem if a host is present, otherwise the window plus a desktop notification for state.
5. **Packaging order**: **.deb (and .rpm) first**, since nothing is blocked and we can ship the uinput udev rule as an opt-in. Then **Flatpak** on the portal-only path (no `--device=all`). AppImage is optional.

Not doing yet: GNOME Shell extension and KWin scripts (per-compositor code that breaks across versions), and system-audio capture.

---

## 6. Lessons from open-source tools

| Tool | What it is | Learn / avoid |
|---|---|---|
| **nerd-dictation** ([repo](https://github.com/ideasman42/nerd-dictation)) | One Python file, VOSK, `begin`/`end`/`cancel` commands the user binds to keys, no daemon | **Learn**: the CLI begin/end model works on every desktop with no permissions. User text processing is a plain Python file. Several typing backends (xdotool, ydotool, dotool, wtype, stdout). **Avoid**: VOSK accuracy is well below Whisper, and toggle-only start means no push-to-talk. |
| **Speech Note** (dsnote, [repo](https://github.com/mkiol/dsnote)) | Qt app, many engines (whisper.cpp, Faster Whisper, Vosk, Parakeet), fully offline, Flatpak-first | **Learn**: GlobalShortcuts portal on Wayland; per-model downloads; GPU as optional add-ons. **Avoid**: "insert into active window" on Wayland needs ydotoold plus a Flatpak socket hole, which is fiddly for users. A note-taking UI first and dictation second. |
| **Handy** ([repo](https://github.com/cjpais/Handy)) | Tauri v2 + Rust, Whisper and Parakeet V3, Silero VAD, cross-platform, offline | **Closest to shepetal.** **Learn**: CLI flags and a `SIGUSR2` toggle for Wayland hotkeys; `--no-tray` and `--start-hidden`; clear dependency notes per session type. **Avoid**: they found enigo (their Rust input library) weak on Wayland; WebKitGTK rendering bugs (`WEBKIT_DISABLE_DMABUF_RENDERER`, flicker); an overlay that steals focus; an X11-only AppImage. |
| **OpenWhispr** ([Linux docs](https://docs.openwhispr.com/platform/linux)) | Electron, open-source Wispr-style app | **Learn**: always copy to the clipboard first, then try a ladder of paste helpers; per-terminal paste keys; register GNOME and KDE shortcuts natively; push-to-talk needs GNOME 48+ or the input group; refuse key combinations the desktop reserves. **Avoid**: Electron global shortcuts fail on Wayland; `hyprctl` binds that do not survive a config reload. |
| **voicsh / Vocalinux / WayType / wdotool** ([voicsh](https://lib.rs/crates/voicsh), [Vocalinux release](https://newreleases.io/project/github/VocaHQ/vocalinux/release/v0.18.0), [WayType](https://www.nuget.org/packages/waytype), [wdotool](https://github.com/cushycush/wdotool)) | Newer Wayland-first tools | **Learn**: the industry is moving to **RemoteDesktop portal / libei** for typing (Vocalinux 0.18 dropped its ydotoold dependency). Vocalinux also switched ydotool to clipboard paste because it does not depend on the keyboard layout. |

Common thread: every tool ends up with a **backend ladder plus clipboard fallback**, and the most common user complaint is setup friction (`input` group, ydotoold, relogin). shepetal should make the portal path the default so most users never touch groups or daemons.

---

## 7. Open questions

1. iOS: resolved. The "cannot start recording from background" rule is cited in section 2 (`AVAudioSession.ErrorCode.cannotStartRecording`).
2. iOS: does Wispr's keyboard call the server itself, or only read results from the App Group? A device test with a proxy would settle it. It matters for how we word the Full Access explanation.
3. iOS: the real keyboard memory cap on iOS 18 and 26 devices. Only 48 MB is sourced, and only secondhand; **~70 MB is unsourced**. Measure with Instruments.
4. iOS: is the responder-chain URL open from a keyboard still working on iOS 26, and has App Review been rejecting it? This is the biggest single risk to the bounce design. If it is dead, the Action Button and Control Center path (`AudioRecordingIntent`) becomes the main way to start a session.
5. iOS: should the cleanup step (an LLM rewrite) run on device in the containing app at all? This is a memory and battery question, and it overlaps with the text-pipeline agent.
6. Linux: the first Plasma release with the GlobalShortcuts portal (5.27 vs 6.x) is not confirmed; check the xdg-desktop-portal-kde git history.
7. Linux: RemoteDesktop portal typing speed and Unicode coverage (keysym per character, non-Latin scripts) on GNOME and KDE. Benchmark against clipboard paste.
8. Linux: does GNOME's GlobalShortcuts backend deliver `Deactivated` reliably enough for push-to-talk? OpenWhispr's note that push-to-talk "needs GNOME 48+" suggests yes. Verify.
9. Android (later): accessibility service vs IME. Wispr chose a bubble over a keyboard; confirm the Play policy for accessibility services that are not assistive tools.
