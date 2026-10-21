# meetings (Windows)

Detects meetings and offers a one-click "Record?" (`Event::OfferRecording`). Nothing records until the user clicks it (`Detector::accept`, or a `()` on the receiver passed to `watch`). Then it records the call as two 16 kHz mono WAVs: `Me.wav` (default mic) and `Others.wav` (WASAPI loopback of the default output), in `%LOCALAPPDATA%\Shepetal\meetings\<yyyyMMdd-HHmmss>\`. The folder's DACL grants only the current user, and recordings are never deleted.

- A meeting is any other app using the mic or the camera (Pavel, 2026-10-21): no app lists and no window titles. Who uses them comes from `HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\{microphone,webcam}`, the records behind Windows' own mic and camera indicators, so detection needs no permission. A packaged app's key is its package family name; a desktop app's, under `NonPackaged`, is its exe path with `#` for `\`. LastUsedTimeStop is 0 while it uses the device; an entry that started before this boot is stale (say, a power loss mid-call) and does not count. The card names the app: the exe name without `.exe`, or the package name.
- shepetal itself never counts, by its exact exe path (`current_exe()`, any case, a `\\?\` prefix dropped), never by name: it keeps its mic open the whole time it runs. The path is compared in the key's `#` form, since turning `#` back into `\` breaks on a path that holds `#` (a user name like `Jo#1`).
- Thresholds (`Config`): offer after 5 s of use; an unanswered offer goes away after 20 s, and no new one comes until the mic and camera are released and used again; the meeting ends once neither has been used by another app for 4 s, never in its first 15 s, and never within 10 s of a default-device change.

The detector, the offer and the record start/stop decision are pure (`Detector::update`, `Detector::accept`), and `in_use` reads the ConsentStore through the `Registry` trait, so they are tested on any OS, the registry with fixtures. On Windows one more test runs the real registry calls on a scratch HKCU key. The Win32 code is `#[cfg(windows)]`.

```sh
cd windows
cargo test -p meetings
cargo check --target x86_64-pc-windows-gnu -p meetings   # rustup target add x86_64-pc-windows-gnu
```
