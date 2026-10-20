# Parity ledger: shepetal vs Wispr Flow

One row per feature ID in `docs/re/feature-inventory.md`, one column per shepetal platform. `python3 scripts/parity.py` checks this table and prints the coverage; the goal is 100% automated and 100% confirmed coverage (see `agent/goal.md`, "The finish line").

Platform mapping: Mac covers Wispr's Mac features, Linux covers Wispr's desktop features (Mac and Windows), iPhone covers Wispr's iOS features plus every desktop feature iOS allows.

Cell values:
- `todo`: not built yet.
- `done`: built and tested. The row's evidence for that platform names the test(s) in backticks and the PR that landed it on main, for example ``Mac: `HotkeyTests.testHoldStartsRecording` #12``.
- `hand-test`: everything automatable is done; the cell waits on a step in `docs/manual-test.md`.
- `confirmed`: set only by Pavel after he runs the hand test.
- `impossible`: the platform forbids it. The evidence for that platform cites the Apple, Linux or kernel doc by URL and names the substitute that was built.
- `n/a`: only for features that exist solely for Wispr's servers or business. The evidence reads `n/a <category>: <reason>`, with the category one of `billing`, `subscriptions`, `referrals`, `telemetry`, `remote-flags`, `ab-tests`, `account-admin`. Cloud-backed user features (sync, sharing, MCP, team dictionaries, cloud ASR) are never n/a; they get a local-first equivalent.

Evidence syntax: segments separated by `;`, each starting with `Mac:`, `Linux:`, `iPhone:` or `All:` (all three). Other text is a free note.

The completeness check (`--completeness /Users/sorcecoder/shepetal-re/identifier-map.tsv /Users/sorcecoder/shepetal-re/identifiers`) maps every Wispr identifier extracted by `python3 -I scripts/extract_identifiers.py` to an F-ID or to `internal` with a reason. The map and the identifier lists stay outside the repo.

| F-ID | Feature | Mac | Linux | iPhone | Evidence / notes |
|---|---|---|---|---|---|
| F01 | Push-to-talk on a hotkey (hold Fn by default) | todo | todo | todo | |
| F02 | Hands-free toggle (press once to start, again to stop) | todo | todo | todo | |
| F03 | Cancel or dismiss dictation (Esc) | todo | todo | todo | |
| F04 | Rebindable shortcuts, multi-key combos, mouse buttons | todo | todo | todo | |
| F05 | Floating Flow Bar / status pill with live waveform | todo | todo | todo | |
| F06 | Start and stop sounds, haptics | todo | todo | todo | |
| F07 | Microphone selection with ranked fallback devices | todo | todo | todo | |
| F08 | Mic health alerts (no audio, disconnected, unreadable, AirPods or clamshell warnings) | todo | todo | todo | |
| F09 | Mute or pause media while dictating | todo | todo | todo | |
| F10 | Max dictation length and duration warnings | todo | todo | todo | |
| F11 | Whisper mode (quiet speech) | todo | todo | todo | |
| F12 | Multi-language with auto-detect | todo | todo | todo | |
| F13 | Streaming text while speaking | todo | todo | todo | |
| F14 | Mouse Flow (dictate via a mouse button) | todo | todo | todo | |
| F15 | BLE mic ring (hands-free over Bluetooth) | todo | todo | todo | |
| F16 | Jabra headset button and wear detection | todo | todo | todo | |
| F17 | Secure Input detection (warns when hotkeys are blocked) | todo | todo | todo | |
| F18 | Slow-processing and degraded-network notices | todo | todo | todo | |
| F19 | Insert text into any app at the cursor (clipboard paste, then restore) | todo | todo | todo | |
| F20 | Paste verification and failed-paste fallback (copy, notify) | todo | todo | todo | |
| F21 | Paste last / copy last transcript shortcuts | todo | todo | todo | |
| F22 | Terminal and remote-desktop paste modes (Shift+Insert, typed paste) | todo | todo | todo | |
| F23 | App and URL awareness (active app, browser URL) | todo | todo | todo | |
| F24 | Textbox and AX context sent to the formatter (text around the cursor) | todo | todo | todo | |
| F25 | Screenshot / OCR context | todo | todo | todo | |
| F26 | Auto-learn words from the user's edits after paste | todo | todo | todo | |
| F27 | Focus restore before paste (store, then refocus the element) | todo | todo | todo | |
| F28 | Link memory: insert recently copied links by voice | todo | todo | todo | |
| F29 | IDE integration: file tagging (@file) in Cursor and other IDEs | todo | todo | todo | |
| F30 | Coding-CLI detection in terminals (claude, codex, aider and others) | todo | todo | todo | |
| F31 | Slack @-mention tagging | todo | todo | todo | |
| F32 | AI formatting / cleanup (filler removal, punctuation, casing) | todo | todo | todo | |
| F33 | Per-app formatting override (raw vs AI per app) | todo | todo | todo | |
| F34 | Backtrack / self-correction ("no wait, I mean ...") | todo | todo | todo | |
| F35 | Smart lists and numbered lists | todo | todo | todo | |
| F36 | Email formatting and an auto email signature | todo | todo | todo | |
| F37 | Styles / tone per app category (work, email, personal, other) | todo | todo | todo | |
| F38 | "My voice" preferences and writing samples (tone match) | todo | todo | todo | |
| F39 | Personal dictionary (vocabulary and replacements) | todo | todo | todo | |
| F40 | Snippets (voice shortcut expands to text, rich text) | todo | todo | todo | |
| F41 | Translate while dictating | todo | todo | todo | |
| F42 | Voice commands: "press enter" | todo | todo | todo | |
| F43 | Command Mode / instruct (voice-edit selected text, ask, act) | todo | todo | todo | |
| F44 | "Hey Flow" wake phrase for command mode | todo | todo | todo | |
| F45 | Polish: rewrite the selected text from a hotkey with saved prompts | todo | todo | todo | |
| F46 | Polish diff view and undo | todo | todo | todo | |
| F47 | Auto-polish after dictation | todo | todo | todo | |
| F48 | Undo AI (revert to the raw transcript) | todo | todo | todo | |
| F49 | Flow Lens: ask about the screen or context via a shortcut chat | todo | todo | todo | |
| F50 | Stacked messages: in personal messaging apps, one dictation is split into several chat messages | todo | todo | todo | |
| F51 | Nonsense or empty transcript guard | todo | todo | todo | |
| F52 | Dictation history with search, copy, retry, archive, audio playback | todo | todo | todo | |
| F53 | Local data policy (store normally, delete after 24h, never store) | todo | todo | todo | |
| F54 | Feedback on a transcript (thumbs, desired text) | todo | todo | todo | |
| F55 | Scratchpad notes window (tabs, pinning, open from a shortcut) | todo | todo | todo | |
| F56 | Note version history and AI transforms on notes | todo | todo | todo | |
| F57 | Images in notes | todo | todo | todo | |
| F58 | Shareable note links | todo | todo | todo | Inventory Skip, but share links are a user feature, not an n/a category: needs a local-first equivalent (share by exported file). |
| F59 | Cloud sync across devices | todo | todo | todo | |
| F60 | Stats: words dictated, WPM, time saved, per-app usage | todo | todo | todo | |
| F61 | Daily streak and milestones | todo | todo | todo | |
| F62 | Insights heatmap and "voice profile" persona card | todo | todo | todo | |
| F63 | Team leaderboard | todo | todo | todo | Inventory Skip, but a team leaderboard is not one of the n/a categories: decide a local-first equivalent or argue n/a in review. |
| F64 | Data export (self-serve) | todo | todo | todo | |
| F65 | Meeting recorder: mic + system audio capture | todo | todo | todo | |
| F66 | Auto-detect meetings (Zoom, Meet, Teams, Slack huddles) and prompt to record | todo | todo | todo | |
| F67 | Auto-start and auto-end recording (detect leaving the call, silence) | todo | todo | todo | |
| F68 | Live transcript during the meeting | todo | todo | todo | |
| F69 | Post-meeting refined transcript | todo | todo | todo | |
| F70 | Speaker attribution and names (from the call UI and participants) | todo | todo | todo | |
| F71 | AI summary and notes (notepad merged with the transcript) | todo | todo | todo | |
| F72 | Action items / todos from meetings | todo | todo | todo | |
| F73 | Ask questions about meetings (chat) | todo | todo | todo | |
| F74 | Calendar integration (Google, Microsoft), upcoming-meeting reminders | todo | todo | todo | |
| F75 | Pre-read briefs before a meeting | todo | todo | todo | |
| F76 | Recording consent notice posted to the meeting chat | todo | todo | todo | |
| F77 | Auto-share notes with participants | todo | todo | todo | Inventory Skip, but sharing notes with participants is a user feature, not an n/a category: needs a local-first equivalent (exported file). |
| F78 | Folders for meetings | todo | todo | todo | |
| F79 | Automations on meetings or notes | todo | todo | todo | |
| F80 | Import from Granola / Otter | todo | todo | todo | |
| F81 | Transcript retention policy | todo | todo | todo | |
| F82 | Hide the recorder in screen share; split-screen next to the call; menu-bar meeting control | todo | todo | todo | |
| F83 | Long-meeting check-in and max length | todo | todo | todo | |
| F84 | Meeting translation | todo | todo | todo | |
| F85 | Org insights (team-level analytics over meetings) | n/a | n/a | n/a | All: n/a account-admin: org-level insights exist for team admins of Wispr org accounts; shepetal has no accounts or orgs. |
| F86 | MCP server exposing notes and meetings to AI clients | todo | todo | todo | |
| F87 | Connectors / connect apps (e.g. Atlassian, Loom) for context | todo | todo | todo | |
| F88 | Permission onboarding (mic, accessibility with drag guidance, screen, system audio) | todo | todo | todo | |
| F89 | Onboarding: mic test, language, shortcut, try-it-yourself | todo | todo | todo | |
| F90 | Permission-revoked detection and re-prompt | todo | todo | todo | |
| F91 | Hub main window (home, history, dictionary, snippets, styles, notes, settings) | todo | todo | todo | |
| F92 | Launch at login, hide the Dock icon, menu-bar presence | todo | todo | todo | |
| F93 | Dark mode / theme | todo | todo | todo | |
| F94 | UI localization | todo | todo | todo | |
| F95 | Focus mode (block distracting apps and URLs) | todo | todo | todo | Inventory Skip, but focus mode is a user feature, not an n/a category: needs a local implementation. |
| F96 | Typing reminder (nudges you to use voice when you type a lot) | todo | todo | todo | |
| F97 | Deep links (`wispr-flow://`) for login and actions | todo | todo | todo | |
| F98 | Auto-updater (deferred while dictating) | todo | todo | todo | |
| F99 | Helper crash recovery and relaunch | todo | todo | todo | |
| F100 | In-app notifications center (tips, server announcements) | todo | todo | todo | |
| F101 | Extensions / agent tool bridge (spawns external agent CLIs) | todo | todo | todo | |
| F102 | Admin app deny-list (dictation blocked in some apps) | todo | todo | todo | |
| F103 | HIPAA mode / enterprise data controls | n/a | n/a | n/a | All: n/a account-admin: HIPAA BAA and enterprise data controls are org-account administration; shepetal sends no data anywhere. |
| F104 | Accounts, SSO, teams, team dictionary / snippets | todo | todo | todo | Inventory Skip, but mixed: accounts, SSO and teams are account-admin (n/a), while team dictionary / snippets are a cloud-backed user feature that needs a local-first equivalent (shared folder). Split into separate F-IDs. |
| F105 | Subscriptions, trials, weekly word limit, referrals, student plan, paywalls | n/a | n/a | n/a | All: n/a subscriptions: plans, trials, word limits, referrals and paywalls only serve Wispr's billing; shepetal is free and local. |
| F106 | Product analytics, session telemetry, Sentry, Datadog logs | n/a | n/a | n/a | All: n/a telemetry: product analytics and crash/log upload only serve Wispr; shepetal keeps logs local. |
| F107 | Remote feature flags and A/B experiments | n/a | n/a | n/a | All: n/a remote-flags: remote feature flags and A/B experiments only serve Wispr; shepetal uses compile-time features. |
| F108 | Mobile keyboard dictation (iPhone keyboard extension + app) | todo | todo | todo | |
| F109 | Smart spacing at insertion boundaries (leading or trailing space, nbsp, capitalization based on surrounding text) | todo | todo | todo | |
| F110 | Formality mismatch detection (notices when the tone does not fit the app) | todo | todo | todo | |
| F111 | Feature tour / what's-new / changelog | todo | todo | todo | |
| F112 | Double-trigger debounce (ignores accidental double presses, conflicting shortcuts) | todo | todo | todo | |
