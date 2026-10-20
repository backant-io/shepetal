# shepetal v1 rubric (starter, tune the criteria)

- A pull request against backant-io/shepetal main exists. Its commits are authored by Pavel Hegler and contain no Co-Authored-By lines or mentions of Claude.
- From a clean clone, the README's build command builds the menu-bar app on macOS without errors, and the build output shows it.
- Unit tests cover the fn gesture logic (hold = push-to-talk, double-tap = hands-free, tap ends hands-free, timing thresholds) and model selection by chip and memory, and they pass. The test output shows it.
- Text is inserted at the focused cursor through Accessibility, with a paste fallback that restores the clipboard. Both paths exist in the code.
- Transcription is on-device only. No network request happens during transcription, and model weights are not committed.
- docs/ includes benchmark numbers measured on this Mac for at least two candidate models, and the choice of default follows from them.
- docs/wispr-flow-findings.md explains how Wispr Flow detects fn, tells hold from double-tap, and inserts text, with evidence. The repo contains no Wispr Flow code, strings, or assets.
- The app menu has Donate items linking to https://buymeacoffee.com/sorcecoder and https://github.com/sponsors/backant-io.
- docs/manual-test.md gives exact steps for granting permissions and checking every behavior by hand.
- No TODOs, placeholder text, or dead code remain.
