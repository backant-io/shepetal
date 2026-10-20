## Overview
Weekly release sync for version 2.4 covering an audio crash on older iPhones, the release date and the onboarding copy.

## Key points
- The top crash affects iPhone 11 and older when the audio session is activated twice after the microphone dialog; a forty-line fix exists on a branch.
- QA wants the full audio regression suite run because a previous audio change broke Bluetooth headsets.
- Releasing on Monday morning is risky because support is thin.
- Onboarding screen one is too long and screen three wrongly mentions cloud sync although everything stays on the device.

## Decisions
- The audio session crash fix goes into 2.4, but only after QA passes the audio regression suite.
- The release moves from Monday the 3rd to Tuesday the 4th.
- Screen two stays as is; screen one is shortened and the cloud wording is removed from screen three.
- No A/B test of the onboarding copy in this release; revisit in 2.5.

## Action items
- Tom: open the pull request for the audio session fix (due Wednesday).
- Priya: run the audio regression suite and post results in the release channel (due Thursday).
- Priya: draft the release notes (due Monday).
- Maya: update the roadmap and tell the support team about the new date.
- Maya: follow up with Leo and get the revised onboarding copy (due Friday).
