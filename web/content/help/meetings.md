---
title: Meetings
description: How meeting detection, recording, transcripts and summaries work in Shepetal.
order: 6
---

# Meetings

**Meetings in the Mac app are coming soon.** The detection is built and tested on its own, but it is not in the app yet. This page describes what is built and marks the rest.

## Detection

Shepetal notices when a call starts on your Mac:

- **Apps:** Zoom, Microsoft Teams, Slack huddles, FaceTime, Webex and Discord.
- **Browsers:** Google Meet, Teams on the web and Zoom on the web in Chrome, Safari, Arc, Firefox and Edge.
- **Calendar:** during a calendar event, any other app using the mic counts too.

A meeting starts once an app has held the mic for about 5 seconds, and ends a few seconds after the call lets go of it. Switching your mic or headphones during a call does not end it. Your own dictation never counts as a meeting.

Detecting browser meetings needs Screen Recording access, and calendar matching needs Calendar access. Shepetal never asks for these just to detect; without them it detects meeting apps only.

## The Record prompt

**Coming soon.** Shepetal will ask before it records a meeting. Nothing is recorded until you choose to.

## Ask before you record

Tell everyone in the call that you are recording and transcribing, and get their agreement first. In many places this is required by law. Recording stays on your Mac, but the people you talk to still deserve to know.

## Transcripts and summaries

**Coming soon.** Your side and the other side are recorded as separate tracks and transcribed on your Mac with on-device speech recognition. Summaries are made on your Mac too, without sending anything anywhere.

## Export

**Coming soon.**
