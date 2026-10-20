## Overview
Design review of the meeting notes feature covering the summary panel layout, speaker names and export formats.

## Key points
- Option A puts the summary in a right sidebar; option B uses a bottom sheet.
- In testing with five users, four preferred the sidebar on desktop and all preferred the bottom sheet on the phone.
- Users disliked generic labels such as Speaker 1 because the notes were useless to forward.
- Remembering speakers across meetings needs voice embeddings on the device, which raises a privacy question.
- Users asked for Markdown and plain text export, nobody asked for PDF.

## Decisions
- Use the sidebar on wide windows and the bottom sheet on narrow windows and phones, with the breakpoint at 900 points.
- Speakers can be renamed by tapping the label, per meeting only, with no voiceprints stored in version one.
- Any future cross-meeting voice memory must be opt-in.
- Ship Markdown and plain text export and skip PDF for now.

## Action items
- Omar: update the mockups with the breakpoint and the rename interaction (due Tuesday).
- Grace: write and share the user testing summary (due Wednesday).
- Lena: write the spec for speaker renaming and export formats and send it to engineering (due Friday).
- Lena: book a follow-up review (due next Thursday).
