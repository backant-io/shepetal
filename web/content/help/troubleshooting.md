---
title: Troubleshooting
description: Fixes for fn switching the language, permissions that stay yellow, no audio, and Bluetooth mics.
order: 9
---

# Troubleshooting

## fn switches the language or opens emoji

macOS uses the 🌐 (fn) key for itself. Set **System Settings > Keyboard > Press 🌐 key to** to **Do Nothing**. Shepetal setting this for you is coming soon.

If Wispr Flow or another dictation app also uses fn, both hear it and both type. Quit the other app or move its shortcut off fn.

## Permissions stay yellow

- Open the 🤫 menu, choose **Permissions…**, and click **Grant…** next to each ⚠️ row. Rows turn ✅ within a couple of seconds.
- In **System Settings > Privacy & Security**, check that Shepetal is switched on under **Microphone**, **Input Monitoring** and **Accessibility**.
- If it is on but the row stays ⚠️, remove Shepetal from that list with the − button, add it again, and reopen Shepetal.
- If you turn a permission off while Shepetal runs, 🤫 turns yellow and the permissions window opens. The yellow clears once it is back on.
- "fn is not being watched yet" in the 🤫 menu means Input Monitoring is still off.

## Nothing is typed, or "No speech heard"

- Check the input level in **System Settings > Sound > Input**. Shepetal uses the input selected there. Choosing a mic inside Shepetal is coming soon.
- "No speech heard" means the recording was too quiet or had no words. Speak a little closer to the mic. Very quiet mics can lower the threshold with `defaults write io.backant.shepetal speechFloorDb -float -65`, then reopen Shepetal.
- "No microphone" means macOS reports no input device. Plug one in or pick one in Sound settings.
- If the text went nowhere, it may be on the clipboard. See [When text goes to the clipboard](clipboard). Every dictation is also under **Recent** in the 🤫 menu.

## Bluetooth mics and AirPods

- Shepetal opens the mic only while you dictate. With Bluetooth headphones, macOS switches them to a lower-quality call mode while the mic is open, so music may sound worse for a moment. That is macOS, not a fault.
- Some Bluetooth mics take a moment to wake up. If your first word goes missing, pause for a moment after 🤫 turns red before you speak.
- For better accuracy, pick your Mac's built-in mic in **System Settings > Sound > Input** and keep listening on your headphones.

## Still stuck

Open an issue on [GitHub](https://github.com/backant-io/shepetal/issues) with what you see next to 🤫.
