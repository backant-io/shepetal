---
title: Troubleshooting
description: Fixes for fn switching the language, permissions that stay yellow, no audio, and Bluetooth mics.
order: 9
---

# Troubleshooting

## fn switches the language or opens emoji

Shepetal sets **System Settings > Keyboard > Press 🌐 key to** to **Do Nothing** when it installs and again at every launch. If fn still switches the language, quit and reopen Shepetal, or set it to **Do Nothing** yourself.

If you clicked **Restore 🌐 key setting** in Settings, fn goes back to your old behavior until Shepetal starts again.

If Wispr Flow or another dictation app also uses fn, both hear it and both type. Quit the other app or move its shortcut off fn.

## Permissions stay yellow

- Choose **Permissions needed…** at the top of the 🤫 menu, and click **Grant…** next to each ⚠️ row. Rows turn ✅ within a couple of seconds.
- In **System Settings > Privacy & Security**, check that Shepetal is switched on under **Microphone**, **Input Monitoring** and **Accessibility**.
- If it is on but the row stays ⚠️, remove Shepetal from that list with the − button, add it again, and reopen Shepetal.
- If you turn a permission off while Shepetal runs, 🤫 turns yellow and the permissions window opens. The yellow clears once it is back on.
- If **Home** says the fn key is not watched yet, Input Monitoring is still off.

## Nothing is typed, or "No speech heard"

- Choose **Microphone** in the 🤫 menu and check which mic is in use. **Automatic** picks your preferred mic that is plugged in, then the system default. You can also pick one mic to always use.
- "No speech heard" means the recording was too quiet or had no words. "Speak closer or use a wired mic" means it was very quiet.
- "No sound from <mic>. Is it muted?" means that mic is sending silence. Unmute it or pick another one in the 🤫 menu.
- "No microphone found" means macOS reports no input device. Plug one in.
- With the lid closed, a MacBook's built-in mic can't hear you. Shepetal says so and needs another mic.
- Fn does nothing and a sign-in note shows? Sign in, or buy after your trial. See [Trial and license](trial-and-license).
- If the text went nowhere, it may be on the clipboard. See [When text goes to the clipboard](clipboard). Every dictation is also under **Recent** in the 🤫 menu.

## Bluetooth mics and AirPods

- The built-in mic records clearer than Bluetooth. Shepetal reminds you of this once.
- With Bluetooth headphones, macOS switches them to a lower-quality call mode while the mic is open, so music may sound worse for a moment. That is macOS, not a fault.
- For the best accuracy, choose your Mac's built-in mic in **Microphone** in the 🤫 menu and keep listening on your headphones.
- If a Bluetooth mic disconnects mid-dictation, "Mic disconnected" shows and what you said up to then is still inserted.

## Still stuck

Choose **Send feedback…** in the 🤫 menu, or open an issue on [GitHub](https://github.com/backant-io/shepetal/issues) with what you see next to 🤫.
