---
title: Your recordings
description: Where Shepetal keeps your audio and history, and how long.
order: 5
---

# Your recordings

Every dictation's audio is saved on your Mac, including too-short, cancelled and failed ones. It never leaves your computer.

## Where

`~/Library/Application Support/Shepetal/audio`, one audio file per recording. Only your user account can read the folder and its files. The history is in `history.sqlite` in the same place, and meetings are in `meetings` next to it.

To open the folder, go to **Open shepetal > Settings > Open recordings folder**.

## What history stores

For each dictation: the text, the time, the outcome (for example "too short" or "no speech"), the app you dictated into and, in common browsers, the page address. All of it stays in `history.sqlite` on your Mac.

## What you can do with a recording

In **Open shepetal > History**:

- **Search** your dictations and **Copy** the text.
- **Play** the recording.
- **Re-transcribe** it with the speech recognition in use, or the other one if you have it installed.
- **Archive** an entry to hide it. Tick **Show archived** to see it again.

## Retention

Choose under **Recordings** in **Open shepetal > Settings**:

- **Keep recordings** (the default).
- **Delete recordings after 24 hours.** Older audio is removed straight away and then checked every hour. The text in history stays, and those rows show "recording deleted". The same choice applies to meeting recordings.

There is no option to never save audio. It is your own audio on your own Mac, and keeping it is what makes playback and re-transcribing possible.
