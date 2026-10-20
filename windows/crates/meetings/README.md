# meetings (Windows)

Detects calls and records them as two 16 kHz mono WAVs: `Me.wav` (default mic) and `Others.wav` (WASAPI loopback of the default output), in `%LOCALAPPDATA%\Shepetal\meetings\<yyyyMMdd-HHmmss>\`. The folder's DACL grants only the current user, and recordings are never deleted.

- Mic holders: active audio sessions on every active capture device.
- Apps: `zoom.exe`, `ms-teams.exe` / `Teams.exe`, Webex (`webex.exe`, `CiscoCollabHost.exe`, `atmgr.exe`) and `discord.exe` count on their own. `slack.exe` counts only while a Slack window title says "huddle". Chrome, Edge, Firefox, Brave and Arc count only while the browser's own window is in front with a Meet, Teams or Zoom web title. shepetal's own process never counts.
- Thresholds (`Config`): start after 5 s, no end in the first 15 s, after the mic is released, end after 3 s (raised to the 4 s reacquire window) when nothing still proves the call, or after 30 s while the browser tab or huddle window is still there; no end within 10 s of a default-device change.

The detector and the record start/stop decision are pure (`Detector::update`), so they are tested on any OS. The Win32 code is `#[cfg(windows)]`.

```sh
cd windows
cargo test -p meetings
cargo check --target x86_64-pc-windows-gnu -p meetings   # rustup target add x86_64-pc-windows-gnu
```
