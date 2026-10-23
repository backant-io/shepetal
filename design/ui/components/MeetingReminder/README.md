# MeetingReminder
The meeting reminder: the one thing shepetal floats, asking once whether to record a call that is starting.

- **Provide:** `<div class="sh-reminder sh-enter" role="dialog" aria-label="Meeting reminder">` with the indicator, a title naming the call app ("Meeting detected · Zoom" or the calendar title), and two actions: `Record` (primary) and `Not now` (secondary).
- It opens above the indicator, left-aligned with it, on `sh-bg-raised` with `sh-pop`. It enters 8 px up over `sh-dur-slow` and leaves in `sh-dur-base`.
- It never steals focus from the call app and never makes a sound. It leaves on its own after 12 s if nobody answers, which counts as Not now.
- While the meeting records, the reminder is gone and the indicator shows Recording.
