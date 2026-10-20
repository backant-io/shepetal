---
title: Your recordings
description: Where Shepetal keeps your audio and history, and how long.
order: 5
---

# Your recordings

Every dictation's audio is saved on your Mac, including too-short, cancelled and failed ones. It never leaves your computer.

## Where

`~/Library/Application Support/Shepetal/audio`, one audio file per recording. The folder and files can be read only by your user account. The history is in `history.sqlite` in the same place.

Open the folder from the 🤫 menu with **Open recordings folder**, or from **Settings** in the Shepetal window.

## What history stores

For each dictation: the text, the time, the outcome (for example "too short" or "no speech"), the app you dictated into and, in common browsers, the page address. All of it stays in `history.sqlite` on your Mac.

## What you can do with a recording

In the Shepetal window, under **History**:

- **Search** your dictations and **Copy** the text.
- **Play** the recording.
- **Re-transcribe** it with the current speech model, or another one you have installed.
- **Archive** an entry to hide it. Tick **Show archived** to see it again.

## Retention

Choose under **Recordings** in the 🤫 menu, or in **Settings**:

- **Keep recordings** (the default).
- **Delete recordings after 24 hours.** Older audio is removed straight away, and then checked every hour. The text in history stays. Those rows show "recording deleted".

There is no option to never save audio: it is your own audio on your own Mac, and keeping it is what makes playback and re-transcribing possible.
