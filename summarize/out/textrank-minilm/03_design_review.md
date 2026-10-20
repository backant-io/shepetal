## Overview
Welcome to the design review for the meeting notes feature.

## Key points
- Today I want to settle the layout of the summary panel and how we handle speaker names.
- That's easy to do with the adaptive layout we already use for settings.
- That needs voice embeddings stored on the device.
- I'd keep it simple for the first version.
- We can revisit voice memory later with an explicit opt-in.

## Decisions
- We use the sidebar on wide windows and the bottom sheet on narrow windows and phones, with the breakpoint at nine hundred points.
- We don't store voiceprints in version one.
- Tap to rename speakers, per meeting only, no cross-meeting voice memory.
- Let's ship Markdown and plain text, and skip PDF for now.

## Action items
- Omar: update the mockups (due Tuesday)
- Grace: write the testing summary and share it (due Wednesday)
- Lena: write the spec for speaker renaming and the export formats, and send it to engineering (due Friday)
- Lena: book a follow-up review (due next Thursday)
