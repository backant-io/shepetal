---
title: Meetings
description: How Shepetal notices a call, asks before it records, and writes transcripts and summaries on your Mac.
order: 6
---

# Meetings

## Detection

When another app has used your mic or a camera for 5 seconds, such as Zoom, Teams, a Slack huddle, Google Meet in a browser or any other app, Shepetal notices. It needs no Screen Recording or Camera access for this. Your own dictation never counts as a meeting.

## The Record prompt

A small card shows just above 🤫: "Meeting detected · zoom.us" (the app using the mic, or "Camera" when only a camera is on), with **Record** and **Not now**.

- Nothing records until you click **Record**.
- **Not now**, or letting the card go away after 20 seconds, records nothing for that meeting.
- Clicking the card doesn't take focus away from your call.
- To start by hand, choose **Record meeting** in the 🤫 menu.
- To skip the question, turn on **Always record meetings automatically** in **Open shepetal > Settings**. It is off by default.

While a meeting records, 🤫 keeps a red ring the whole time, even while you dictate, and the menu bar shows 🤫●. Choose **Stop meeting recording** in the 🤫 menu to stop.

## Ask before you record

Tell everyone in the call that you are recording and transcribing, and get their agreement first. In many places this is required by law. The recording stays on your Mac, but the people you talk to still deserve to know.

## Transcripts and summaries

Your mic and the call audio are recorded as two separate tracks, so the transcript can tell you apart from everyone else. Both are transcribed on your Mac with on-device speech recognition. The summary is written on your Mac too, and nothing is sent anywhere.

When a meeting ends, its transcript opens in a window without pulling you out of the app you are in. The summary is added once it's ready.

## Finding and exporting meetings

- **Past meetings** in the 🤫 menu opens your 8 newest meetings.
- **Open shepetal > Meetings** lists them all, with search and a Summary view and a Transcript view.
- **Copy transcript** and **Copy summary** put the text on your clipboard.
- **Export Markdown…** saves the meeting as a Markdown file.

Meeting audio is kept in `~/Library/Application Support/Shepetal/meetings`, readable only by your user account, and follows the same retention choice as your recordings.
