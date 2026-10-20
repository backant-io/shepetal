## Overview
Option A puts the summary in a right sidebar next to the transcript.

## Key points
- Today I want to settle the layout of the summary panel and how we handle speaker names.
- Before we start, I shared two mockups in the design folder, option A with a sidebar and option B with a bottom sheet.
- On a laptop it's great because you see both at once.
- Right now the transcript shows Speaker 1, Speaker 2 and so on.
- Yes, that should be opt-in if we ever do it.

## Decisions
- We use the sidebar on wide windows and the bottom sheet on narrow windows and phones, with the breakpoint at nine hundred points.
- We don't store voiceprints in version one.
- Tap to rename speakers, per meeting only, no cross-meeting voice memory.
- Let's ship Markdown and plain text, and skip PDF for now.

## Action items
- Omar: update the mockups (due Tuesday)
- Grace: write the testing summary and share it (due Wednesday)
- Lena: write the spec for speaker renaming and the export formats , and send it to engineering (due Friday)
- Lena: book a follow-up review for (due next Thursday)
