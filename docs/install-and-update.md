# Install and update on the Mac

Design, 21.10.26. This doc covers the Mac installer and auto-updates that Pavel asked for ("a proper installer and auto updates"). It follows his decision of 21.10.26: **a drag-and-drop DMG, no .pkg**. It replaces the .pkg from #112 and covers F98 (auto-updater, deferred while dictating) and part of F88 (permission onboarding). Implementation slices are at the end, followed by the list of what Pavel must provide.

**Status (21.10.26, feat/mac-installer-updates):** slices 1 to 5 are built: signing, the DMG, onboarding, Move to Applications, Uninstall in Settings, Sparkle with the idle gate, and the release pipeline, which runs as a dry run until the credentials exist. The Sparkle EdDSA key pair was generated in Pavel's login Keychain (its public key is in make-app.sh). Not built: slice 6 (the web `/appcast.xml` and `/download` on feat/web), the admin prompt for a root-owned copy when moving or uninstalling (it says to use Finder instead), the "Ask" button for System Audio (macOS asks at the first meeting), and `SURequireSignedFeed` (off, because the Worker's empty fallback feed is unsigned; generate_appcast signs the feed anyway).

## What exists today (checked 21.10.26)

| Area | State |
|---|---|
| Signing identities on the build Mac | One: `Apple Development: founder@backant.io (95MRXK88PF)`, team `MZ5HWASW58`, O = Pavel Hegler, valid to 14.07.27. **No Developer ID Application, no Developer ID Installer** (`security find-identity -v -p codesigning`). |
| Installed app (`/Applications/Shepetal.app`) | 0.1.0, build 439, owned by the user (not root), no .pkg receipt. Designated requirement (DR): `identifier "io.backant.shepetal" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: founder@backant.io (95MRXK88PF)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */`. No hardened runtime (`flags=0x0`). |
| `scripts/make-app.sh` | Builds and signs `dist/Shepetal.app`. It already prefers a "Developer ID Application" identity, and `--zip` writes the release zip. It has no `--options runtime`, no entitlements and no `--timestamp`, so a Developer ID build would still fail notarization. `CFBundleVersion` = `git rev-list --count HEAD`. |
| `scripts/make-pkg.sh`, `scripts/pkg/`, `scripts/test-pkg-scripts.sh` | The .pkg from #112: it installs to /Applications, and its postinstall sets the 🌐 key, turns on Start at login (`Shepetal --postinstall`) and opens the app. The package is unsigned (no Installer identity). |
| `scripts/uninstall-mac.sh` | Also shipped as `Contents/Resources/uninstall.sh`. It quits the app, runs `--unregister-login-item`, restores the 🌐 key and removes the app with `rm -rf`. Recordings are kept unless `--delete-data` is given. It leaves the 1 GB speech model in `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`. |
| In the app | `FnKeySetting.apply` sets the 🌐 key to Do Nothing at every launch, only as `io.backant.shepetal` (#112). `LoginItem` uses `SMAppService.mainApp`. `Onboarding` (`Permissions.swift`) is a window with live status (1 s timer) for Microphone, Input Monitoring and Accessibility. `MeetingRecorder.systemAudioStatus()` reads TCC for System Audio Recording. `TokenStore.delete` signs out. The 🤫 menu (#210) already has a greyed-out **Check for Updates…** behind `protocol UpdateChecking` / `NoUpdateChecker`. |
| Release and workflow | One GitHub release: `v0.1.0-mac`, a **pre-release** with `Shepetal-0.1.0.pkg` and `Shepetal-0.1.0-mac.zip` (+ `.sha256`), built from `6298f40`. On main, the only workflows are `ci.yml` and `windows.yml`; no Mac release workflow exists. The repo has 0 Actions secrets and 0 environments. `#114` (open) adds `linux-release.yml`, which triggers on tags `v*`. |
| Web `/download` (feat/web, #69) | `web/src/lib/download.ts` resolves `releases/latest` and picks `Shepetal-*.pkg`. `releases/latest` skips pre-releases, so today it 404s and shows "coming soon". |
| Brand | `brand/` exists only on the local `feat/brand` branch (2.1, not pushed). Palette: blush `#FAEEE8`, dusk `#1C0A13`, ink `#26141C`, Mulberry 600 `#9E3664` (day accent), Mulberry 700 `#7A244B` (afterglow), with Newsreader (wordmark) and Hanken Grotesk. |
| Sparkle | Not in `Package.swift`. No EdDSA key in the login Keychain. |

## The target in one line

Download `Shepetal-<v>.dmg` → drag it to Applications → first launch: offer to move if needed, then onboarding (permissions, sign-in, Start at login, a test dictation) → Sparkle checks daily and installs only when Shepetal is idle → **Uninstall Shepetal…** sits at the bottom of Settings, behind a confirmation sheet.

## 1. Distribution

### Signing and notarization

- **Identity:** `Developer ID Application: Pavel Hegler (MZ5HWASW58)`, or the organization's identity if Pavel enrolls one (decide before the first release, see *Pavel must provide*). No Developer ID Installer is needed because there is no .pkg.
- **Hardened runtime**, required for notarization. `make-app.sh` signs with `--options runtime --timestamp --entitlements scripts/Shepetal.entitlements`. The entitlements file holds one key, `com.apple.security.device.audio-input = true` (the microphone under the hardened runtime). Meetings use Core Audio process taps, which need only TCC and no entitlement. `dlopen` of the system's private TCC framework passes library validation. Every framework we embed is signed by us. Nothing needs JIT, `disable-library-validation` or Apple Events. The implementer checks this on a notarized build with a real dictation, a real meeting and the cleanup model.
- **Nested code is signed inside-out, never with `--deep`:** each framework in `Contents/Frameworks`, Sparkle's helpers (see 3), then the app.
- **Notarize the DMG, not the app separately.** Order: sign the app → build the DMG → sign the DMG (`codesign --sign "$ID" --timestamp`) → `xcrun notarytool submit Shepetal-<v>.dmg --wait` → `xcrun stapler staple` and `stapler validate`. Notarizing the DMG covers the app inside it, so one submission is enough.
- **Checks after stapling** (a failure stops the release): `spctl -a -vv -t open --context context:primary-signature Shepetal-<v>.dmg`, then mount it and run `spctl -a -vv -t exec` on the app inside, plus the DR check in 3.
- **Credentials, never in the repo:**

| Secret | On Pavel's Mac | In GitHub Actions (environment `mac-release`) |
|---|---|---|
| Developer ID Application certificate + private key | login Keychain | `MAC_DEVELOPER_ID_P12` (base64 .p12), `MAC_DEVELOPER_ID_P12_PASSWORD` |
| App Store Connect API key for notarytool | `xcrun notarytool store-credentials shepetal-notary …` (login Keychain) | `NOTARY_KEY_P8` (base64 .p8), `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` |
| Sparkle EdDSA private key | login Keychain (`generate_keys`) | `SPARKLE_ED_PRIVATE_KEY` |

In CI, the .p12 is imported into a throwaway keychain in `$RUNNER_TEMP`. The keychain password is random per run (`openssl rand`), so it is not a secret. The workflow runs `security set-key-partition-list -S apple-tool:,apple:` so codesign can use the key without a prompt. Every key file is written 0600 to `$RUNNER_TEMP` and deleted in an `always()` step, together with the keychain. No secret is passed on a command line, where `ps` could show it.

### The DMG: drag and drop

`scripts/make-dmg.sh` replaces `scripts/make-pkg.sh`. It defaults to `REQUIRE_SIGNIN=1` as make-pkg.sh does today, and it writes `dist/Shepetal-<v>.dmg` plus a `.sha256`.

- **Built with `dmgbuild`**, pinned exactly and run with `uvx` (uv is already installed in CI). It writes the Finder layout (`.DS_Store`) directly, so it never scripts Finder, which fails on a headless runner. The settings file is `scripts/dmg/settings.py`.
- **Volume** `Shepetal`, format ULFO. The volume icon is the 🤫 `AppIcon.icns`.
- **Finder window** 640 × 400 pt with no toolbar, sidebar or status bar, in icon view with 128 pt icons. `Shepetal.app` is at (160, 200) and the `Applications` alias at (480, 200).
- **Background:** `scripts/dmg/background.tiff`, 1x + 2x, made with `tiffutil -cathidpicheck`. It is rendered once from the brand tokens and committed; it is regenerated only when the brand changes:
  - blush `#FAEEE8` ground with the paper grain, as the brand's day ground;
  - the wordmark "shepetal" in Newsreader, ink `#26141C`, top center;
  - a curved arrow from the app to Applications in Mulberry 600 `#9E3664`, the one accent;
  - "Drag Shepetal into Applications" in Hanken Grotesk 13 pt, neutral 600 `#6C5B5E`, under the icons.
  - The renderer is a Swift script like `scripts/make-icon.swift`. It takes the font paths as arguments, so it runs from `brand/fonts` on feat/brand, and the public repo gets only the rendered TIFF (see *Pavel must provide*, brand).
  - Finder draws the icon labels in the system text color, so check them in both Light and Dark appearance (M-DMG-1).
- **The release ships the DMG only.** The same signed, notarized, stapled DMG is the Sparkle update archive (Sparkle installs from a DMG), so there is no zip and no second notarization. The .pkg is gone.

### What the .pkg did now lives in the app

| .pkg step (#112) | Where it goes |
|---|---|
| Install to /Applications | The user drags the app. If it runs from elsewhere, it offers to move itself (below). |
| 🌐 key to Do Nothing | Nothing new: `FnKeySetting.apply` already runs at every launch and says so next to 🤫. The installer-only path (`fnKeyNoticePending`, `.changedByInstaller`) is deleted. |
| Start at login | Offered in onboarding (2) through `SMAppService.mainApp.register()`. The toggle in Settings stays. `--postinstall` is deleted. |
| Open the app | The user opens it from Applications or the DMG. |
| Uninstaller | **Uninstall Shepetal…** in Settings (below). `uninstall.sh` stays as the fallback for an app that won't open. |

#### Move to Applications

At launch, before onboarding, the app checks where `Bundle.main.bundleURL` is. It offers the move when the app is on a read-only volume (the DMG; `volumeIsReadOnly`), under `/Volumes/`, under `~/Downloads`, or App Translocated (the path contains `/AppTranslocation/`). It is not offered in any `Applications` folder, or when the bundle ID is not `io.backant.shepetal`.

- An alert asks once (`movePromptShown` in defaults): **"Move Shepetal to Applications?"** "It updates itself only from there." The buttons are **Move to Applications** (default) and **Not Now**.
- **Move** copies the bundle to `/Applications/Shepetal.app` and removes `com.apple.quarantine` from the copy (the user has already approved this download). Then it opens the copy as a new instance and quits. An existing `/Applications/Shepetal.app` with our bundle ID is handled by version:
  - if it is older or the same build, it goes to the Trash first;
  - if it is **newer**, it is opened instead and nothing is replaced (downgrade protection);
  - if it is root-owned (installed by the old .pkg), the copy asks for admin rights through the same `do shell script … with administrator privileges` prompt that `uninstall.sh` uses.
- Permissions belong to the DR, not to the path, so a grant made while the app ran from the DMG still holds after the move.
- Skipped: ejecting the DMG for the user (Finder shows the eject button). Add it when someone asks.

#### Uninstall Shepetal…

It is **not in the 🤫 menu** (Pavel: it must not be clicked by accident). It is the last section of the **Settings** tab in the Shepetal window: a quiet section with no header, and a small secondary-colored link-style button (`.buttonStyle(.link)`, `.foregroundStyle(.secondary)`). It is not red and not prominent. It is hidden when the bundle ID is not `io.backant.shepetal` or the app is on a read-only volume.

Clicking it opens a **sheet**:

> **Uninstall Shepetal?**
> Shepetal will:
> - stop starting at login
> - put back your 🌐 key setting (*Change Input Source*). Only shown when `FnKeySetting.restorable` has a value.
> - sign out on this Mac
> - move Shepetal and the models it downloaded (1 GB or more) to the Trash
> - quit
>
> Your recordings, transcripts and history stay in ~/Library/Application Support/Shepetal.
>
> ☐ **Also delete my recordings**
>
> [ Cancel ] [ Uninstall ]

- **Cancel is the default button** (Return and Esc both cancel). **Uninstall** has `role: .destructive` and is never the default.
- Ticking the box changes the last line to "Your recordings, transcripts and history also go to the Trash."
- **Uninstall is disabled while a dictation, a meeting recording, a transcription or a re-transcribe is under way**, with the reason shown ("Finish the meeting recording first").
- The steps, in this order, come from a pure `UninstallPlan` in ShepetalCore and run with injected I/O, like `FnKeySetting.io`:
  1. `SMAppService.mainApp.unregister()`, while the bundle is still in place, because it needs the bundle;
  2. `FnKeySetting.restore` if there is a stored value;
  3. `TokenStore.delete()` (the account token in the login Keychain);
  4. `tccutil reset All io.backant.shepetal`, best effort, so no stale rows stay in Privacy & Security;
  5. move to the Trash: the model folders `parakeet-tdt-0.6b-v3` and the dictionary model (only those folders, because other apps can share `FluidAudio/`), the cleanup model in `~/Library/Application Support/Shepetal/models` (even when the recordings stay), `~/Library/Caches/io.backant.shepetal` (including Sparkle's downloads), and **only when the box is ticked** `~/Library/Application Support/Shepetal` and the defaults domain;
  6. move `Bundle.main.bundleURL` and any other `Shepetal.app` with our bundle ID in `/Applications` or `~/Applications` to the Trash (`NSWorkspace.recycle`). A root-owned copy from the old .pkg falls back to the admin prompt;
  7. quit.
- **Everything goes to the Trash, nothing is `rm`'d**, so an accidental uninstall is fully undone by dragging the app back out of the Trash, until the Trash is emptied. Only the sign-out, the login item and the TCC reset need redoing, and the onboarding does that.

## 2. First-run onboarding

One window, in SwiftUI like the Hub. It replaces the AppKit `Onboarding` window and shows the same three steps every time. It opens at the first launch (no `onboardingDone` in defaults) and when a required permission is missing (as today). Closing it counts as seen (`onboardingDone`), so it never takes the focus again at every login. **Settings › Permissions…** and the menu's **Permissions needed…** open it at step 1. A pure `OnboardingFlow` in ShepetalCore decides the steps and when Continue is enabled.

1. **Permissions.** One row each, with live status (the existing 1 s refresh) and an **Open** button. On the first click the button asks macOS, so the app appears in the pane, then it opens the pane (today's `grant`).

| Row | Status from | Pane |
|---|---|---|
| Microphone | `AVCaptureDevice.authorizationStatus` | `Privacy_Microphone` |
| Accessibility | `AXIsProcessTrusted()` | `Privacy_Accessibility` |
| Input Monitoring | `CGPreflightListenEventAccess()` | `Privacy_ListenEvent` |
| System Audio Recording, *for meetings, optional* | `MeetingRecorder.systemAudioStatus()` (0 granted, 1 denied, 2 not asked) | "Screen & System Audio Recording". The anchor is checked on 14.4 and 15.x. While it reads "not asked", the button says **Ask** and opens a throwaway process tap for a moment, which is the only way to trigger the macOS prompt. |

   Continue is enabled when the three required rows are ✅. System Audio never blocks.

2. **Sign in with Google.** Shown only when the build requires sign-in (`ShepetalRequiresSignIn`) and the user is signed out. It reuses `AccountSection` and the web login (#195), and shows the trial status once signed in.

3. **Try it.** A text field with the line "Click here, hold fn and say something." While the speech model downloads, its progress shows above the field and the field is disabled. When the dictated text lands in the field, the step shows ✅ "It works". The paste goes through the real pipeline, so this checks the microphone, fn, Accessibility and insertion end to end. Below the field is **☑ Start Shepetal when I log in**, ticked by default, as the .pkg turned it on. It is registered on **Done**, not before, so a closed window changes nothing. Done sets `onboardingDone`.

Not in scope here: the language and shortcut steps of F89. They stay in the 🤫 menu.

## 3. Auto-updates with Sparkle 2

- **Dependency:** `.package(url: "https://github.com/sparkle-project/Sparkle", exact: "<newest 2.x>")`, pinned exactly like FluidAudio. `make-app.sh` already copies `$BIN/*.framework` into `Contents/Frameworks` and adds the rpath. This is a non-sandboxed app, so Sparkle's XPC services are removed from the framework. Its `Autoupdate` and `Updater.app` are signed with `-o runtime --timestamp` before the framework, as Sparkle's docs for Developer ID apps say. The tools `generate_keys` and `sign_update` come from `.build/artifacts/sparkle/Sparkle/bin/`.
- **Only release builds update.** `make-dmg.sh` writes the Sparkle keys into Info.plist. A plain `make-app.sh [--install]` build has no `SUFeedURL`, so the app keeps `NoUpdateChecker` and the 🤫 menu has no Check for Updates… (Pavel, 21.10.26: no grey items). This also means a release never overwrites a dev build that an agent installed on Pavel's Mac.

| Info.plist key | Value |
|---|---|
| `SUFeedURL` | `https://shepetal.backant.io/appcast.xml` |
| `SUPublicEDKey` | the public EdDSA key (public; committed in make-app.sh) |
| `SUEnableAutomaticChecks` | `true`. Sparkle never asks "check automatically?" |
| `SUScheduledCheckInterval` | `86400` (daily) |
| `SUAutomaticallyUpdate` | `true` (download in the background, install under the idle rule) |

  If the pinned Sparkle supports signed feeds (`SURequireSignedFeed`), turn it on and have `sign_update` sign the appcast too.

- **App side:** `SparkleUpdater: UpdateChecking` wraps `SPUStandardUpdaterController`. `canCheckForUpdates` is always true, so the 🤫 menu item shows, enabled; `checkForUpdates()` shows Sparkle's standard dialog, or, while Sparkle downloads in the background (its own `canCheckForUpdates` is false), says "Shepetal is downloading an update" next to 🤫. The menu keeps its 12 items (`MenuModelTests`). Settings gains **☑ Install updates automatically** (bound to `automaticallyDownloadsUpdates`) and "Version 0.2.0 (512)". `SPUStandardUserDriverDelegate.supportsGentleScheduledUpdateReminders = true`: when the user has turned automatic install off, a found update renames the menu item to "Update to 0.2.1…" (same item count), instead of opening a window at a random moment.
- **Idle only, never during a dictation or meeting.** `SPUUpdaterDelegate.updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` returns `true` and keeps the block. A pure `UpdateGate` in ShepetalCore calls it once every minute, and on screen sleep or lock, when all of these hold:
  - no dictation (the `isDictating` closure that `Account.shared.start` already gets, plus `inserting`);
  - no meeting recording, transcription or summary;
  - no re-transcribe in History;
  - **the last fn press was at least 20 minutes ago.** Wispr Flow uses the same rule (docs/re/app-architecture.md 9).

  If Shepetal quits first, Sparkle installs on quit as usual. A manual "Install and Relaunch" from the dialog goes through `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`. It waits only for active work to end (not for the 20 minutes) and says so next to 🤫: "Shepetal restarts to update when the meeting ends."
- **Permissions survive updates.** Sparkle replaces the bundle in place, at the same path. TCC and the Keychain ACL match on the DR, and the Developer ID DR is keyed on the **team**, not on the certificate:

  ```
  identifier "io.backant.shepetal" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = MZ5HWASW58
  ```

  So grants also survive a renewed Developer ID certificate. The release pins this string in `scripts/mac/designated-requirement.txt` and fails if `codesign -d -r-` on the built app differs. That catches a changed bundle ID, team or identity before users have to grant permissions again. **One-time cost:** v0.1.0's DR is keyed on the Apple Development leaf CN, so the first Developer ID build (v0.2.0) has to be granted Microphone, Input Monitoring and Accessibility once more. macOS also asks once to let it read the sign-in token ("Always Allow"), or the user signs in again. v0.1.0 has no Sparkle, so its users download the v0.2.0 DMG by hand once. Say this in the v0.2.0 release notes.
- **EdDSA key:** Pavel runs `generate_keys` once on his Mac. It puts the private key in the login Keychain and prints only the public key, which goes into make-app.sh. Then he runs `generate_keys -x <file>`, `gh secret set SPARKLE_ED_PRIVATE_KEY --env mac-release < <file>` and `rm -P <file>`, and keeps a copy in his password manager. Nobody prints, commits or pastes the private key into a chat. CI writes it to a 0600 file for `sign_update --ed-key-file`. **Losing it:** Sparkle accepts a new EdDSA key only from an update whose Apple code signature still matches, and a new certificate only when the EdDSA key matches; never both in one release. So the key and the team must not change in the same release.
- **Test feed for hand tests:** `defaults write io.backant.shepetal ShepetalFeedURL <https url>` overrides the feed through the delegate's `feedURLString(for:)`, and https is required. Point it at a **pre-release's** `appcast.xml` asset (pre-release assets are public, and the Worker ignores pre-releases) to test an update on one Mac before anyone else gets it.
- **Privacy:** Sparkle's system profiling stays off (its default). A check sends only the app version (User-Agent) to Cloudflare and GitHub.

### Appcast hosting: the Worker, `https://shepetal.backant.io/appcast.xml` (recommended)

The feed URL is baked into every app ever shipped, so it must not depend on the repo's layout:

- **GitHub Releases alone** (`releases/latest/download/appcast.xml`) breaks the Mac feed when a Linux or Windows release in this monorepo becomes "latest". #114 already releases from `v*` tags. Pre-releases make it worse, and the URL can never move.
- **The Worker** route is about 15 lines next to `/download`, on a domain we own. It works the same way:
  - `latestMacRelease()` lists the releases through the GitHub API (edge-cached 5 minutes) and takes the newest one that is **published, not a pre-release, and tagged `v<x.y.z>-mac`**;
  - `/appcast.xml` (public, no sign-in, excluded from any auth middleware) answers with a 302 to that release's `appcast.xml` asset. With no such release it returns an empty valid feed (`<rss><channel/></rss>`), so Sparkle reports "up to date" instead of an error;
  - `/download` changes in the same PR to the same lookup and to `Shepetal-*.dmg`. That also fixes today's coming-soon page;
  - the update archive itself stays on GitHub (`releases/download/v0.2.0-mac/Shepetal-0.2.0.dmg`), on HTTPS.
- The Worker reads only *published* releases, so **publishing the draft is the switch** for `/download` and the appcast together. **Pulling a bad release:** turn it back into a draft or a pre-release, and within 5 minutes everyone who has not updated yet stays on the previous version. Fix forward with a higher build number.
- An optional `GITHUB_TOKEN` Worker secret (fine-grained, public read-only) lifts the 60 requests/hour unauthenticated limit, which the Worker's shared egress IPs may hit. Keep the `!draft` filter, because a token with push access can see drafts.
- This lands in `web/` (PR #69, or after it merges), with tests in `download.test.ts`: drafts, pre-releases, `-linux` and `-windows` tags are skipped; with no Mac release the feed is empty; the DMG is picked over other assets.

## 4. Release pipeline

`.github/workflows/mac-release.yml` triggers on `push: tags: ['v*-mac']` and runs on `macos-26` with the Xcode 26.3 pin from ci.yml. The secrets live only in the environment `mac-release`, which deploys only from `v*-mac` tags and needs Pavel's approval. **They never meet repository code (#227):** the build runs without them, and the jobs that hold them run only Apple's tools and Sparkle's own, written inline in the workflow. Every action is pinned to a commit SHA, and every job has the least `permissions:`.

1. **provenance** (no secrets, no repo code): the tag matches `^v(\d+\.\d+\.\d+)-mac$` (that gives `VERSION`), it is annotated, and its commit is an ancestor of `origin/main`. A tag's commit brings its own copy of the workflow, so this catches a mistaken tag; against a malicious one, the tag ruleset and Pavel's review on `mac-release` are what hold.
2. **build** (no secrets, no cache): `actions/checkout` with **`fetch-depth: 0`** (a shallow clone makes `git rev-list --count HEAD` return 1, which would ship build 1 and never update anyone), `scripts/ci/run-checks.sh --only swift`, then `scripts/mac/release.sh --unsigned`: the guard (`scripts/mac/release_guard.py`: tag format, on main, not shallow, `VERSION` and the build number both **greater** than those of the newest published Mac release, read from its `appcast.xml`), then `make-dmg.sh` with an ad-hoc signature. The DMG is the job's artifact.
3. **sign** (`mac-release`: the Developer ID .p12 and the notary key): the .p12 goes into a throwaway keychain. The app inside the DMG is signed inside-out with the hardened runtime, `--timestamp` and `scripts/mac/Shepetal.entitlements`, and its DR must equal `scripts/mac/designated-requirement.txt` (the job reads those two files and nothing else from the repo). Then the DMG is signed, notarized with the API key, stapled and validated, and the `spctl` checks from 1 run. A rejected notarization prints `notarytool log <id>`.
4. **appcast** (`mac-release`: `SPARKLE_ED_PRIVATE_KEY`): Sparkle 2.10.0's release tarball, checked against its pinned SHA-256 (its `bin/` is byte-identical to the SwiftPM artifact), gives `generate_appcast`, which signs the stapled DMG (**after stapling**, since stapling changes the file) and writes a one-item `appcast.xml` with the GitHub enclosure URL.
5. **verify** (no secrets): `scripts/mac/verify-update.swift` checks the appcast's signature and length against the **`SUPublicEDKey` read from the built app's Info.plist**, and the build number. A wrong or rotated key is the one mistake that silently strands every user, so this check never gets skipped.
6. **draft** (`contents: write`, no repo code): `gh release create v0.2.0-mac --draft` with `Shepetal-0.2.0.dmg`, `.sha256` and `appcast.xml`. Every job deletes its keychain and key files in an `always()` step.

A PR that touches the release path runs `release.sh --dry-run`, then the sign, appcast and verify steps themselves (YAML anchors), ad-hoc and with a throwaway Sparkle key, so the inline release commands are tested before a tag needs them.

**Publishing is Pavel's step and the only trigger:** he downloads the DMG from the draft, tries it, writes the notes and clicks **Publish release** (a full release, not a pre-release). Agents never publish, approve or un-draft a release. The release notes surface in the app is the "What's new" window (#219), so the appcast carries no notes.

Locally `scripts/mac/release.sh` does the whole release with the login Keychain and the notarytool profile `shepetal-notary`. That way Pavel can cut a release by hand if CI is down.

## 5. Uninstall and downgrade protection

**Uninstall** (details in 1):
- It is not in the 🤫 menu. It is the last, quiet item in Settings, behind a sheet whose default button is Cancel, and it is disabled during a dictation or meeting.
- The sheet lists every step. Recordings are kept unless the unticked "Also delete my recordings" is ticked. Everything goes to the Trash, so it can be undone until the Trash is emptied.
- It is hidden for other bundle IDs (test and check builds) and on the DMG.

**Downgrade:**
- **Sparkle never installs a lower `CFBundleVersion`** than the running one, so a stale, cached or tampered appcast cannot roll users back. An archive whose EdDSA signature does not match `SUPublicEDKey`, or that is signed by another team, is refused.
- **Build numbers only go up:** the release guard (4.2) requires a full clone, a tag on main and a build and version greater than the last published release. Its test (`scripts/mac/test-release-guard.sh`) builds a temp git repo and fixture appcasts. It is hermetic, and changing the guard's `>` to `>=` makes it fail.
- **Manual downgrades heal themselves:**
  - moving to Applications never replaces a newer copy (1);
  - an older DMG dragged over a newer app is updated back to the current version by the next daily check, or right away with Check for Updates….
- **Data stays readable by an older build:** `History` and the meeting store migrations are append-only and additive (`ADD COLUMN … DEFAULT`). A build that meets a newer `user_version` runs no steps and reads the columns it knows. That becomes a written rule next to `History.migrations` (no `DROP` or `RENAME`), plus a test: a database at `user_version = migrations.count + 1` with an extra column still opens, reads and inserts.

## Tests

All hermetic: injected I/O, no `SMAppService`, TCC, `defaults` or Trash calls from tests (goal.md: no login items, no TCC changes). Each new test is shown failing by a deliberate break.

| Test | Covers | Deliberate break |
|---|---|---|
| `UninstallPlanTests` | the step order (login item before the bundle moves); the data folder only when ticked; never for another bundle ID or a read-only volume; disabled while busy | drop the "ticked" guard → data appears in the plan |
| `MovePromptTests` | `/Volumes/…`, `~/Downloads/…` and AppTranslocation paths are offered; any Applications folder is not; asked once; a newer installed copy is opened, not replaced | compare builds with `<=` |
| `OnboardingFlowTests` | steps with and without required sign-in; Continue needs the three required permissions; System Audio never blocks; Start at login is registered only on Done | let System Audio block |
| `UpdateGateTests` | dictating, meeting, transcribing and re-transcribe all block; 19:59 since the last fn press blocks, 20:00 allows; a manual install ignores the 20 minutes | 20 → 0 minutes |
| `MenuModelTests` (existing) | still 12 items, and Check for Updates… is enabled with Sparkle | |
| `HistoryTests` (new case) | a newer schema still opens and reads | a migration that drops a column |
| `scripts/mac/test-release-guard.sh` | tag format, ancestry, shallow clone, version and build increase | `>` → `>=` |
| `verify-appcast.swift` self-test | a good signature passes; a flipped byte or another key fails | skip the length check |
| `web/src/lib/download.test.ts` | the newest published `-mac` release; drafts, pre-releases and other platforms skipped; empty feed; DMG asset | match `.pkg` |

Hand tests that replace M-SETUP-1 in docs/manual-test.md:
- **M-DMG-1:** download the DMG in Safari and open it. There is no Gatekeeper warning beyond "downloaded from the internet". Check the window layout and that the labels read well in Light and Dark appearance.
- **M-MOVE-1:** run the app from the DMG. The move is offered once, the app relaunches from /Applications and the permissions are kept.
- **M-ONB-1:** a fresh user account: every row live, sign-in, the test dictation lands in the field, and Start at login is on after Done.
- **M-UPD-1:** with `ShepetalFeedURL` pointed at a pre-release, update 0.2.0 → 0.2.1. Permissions, the login item and the sign-in are kept, and the app relaunches.
- **M-UPD-2:** the update waits during a dictation and a meeting recording, and installs 20 minutes after the last fn press.
- **M-UNINST-1:** uninstall without ticking the box: the app and the model are in the Trash, the login item is gone, the 🌐 key is restored, and the recordings are kept.
- **M-UNINST-2:** with the box ticked, the data is also in the Trash.
- **M-UNINST-3:** with an update downloaded and waiting, an uninstall must not bring the app back (see risks).

## Implementation slices (in order, disjoint files where possible)

1. **Signing:** hardened runtime, entitlements, `--timestamp`, inside-out signing, the pinned DR file and its check (`make-app.sh`, `scripts/Shepetal.entitlements`). This works now with the Apple Development identity. Notarization waits for the certificate.
2. **DMG:** `make-dmg.sh`, `scripts/dmg/`, the background. Delete `make-pkg.sh`, `scripts/pkg/`, `test-pkg-scripts.sh`, `--postinstall` and the installer-notice path, and update the README install section and the hand tests.
3. **In the app:** move to Applications, the onboarding window, Uninstall in Settings (`UninstallPlan`, `MovePrompt`, `OnboardingFlow`).
4. **Sparkle:** the dependency, `SparkleUpdater`, `UpdateGate`, the Info.plist keys, the Settings toggle and the test feed.
5. **Release:** `mac-release.yml`, `release-guard.sh`, `make-appcast.sh`, `verify-appcast.swift`.
6. **Web:** `/appcast.xml` and `/download` → the DMG of the newest published `-mac` release.

Slices 1 to 4 can be built and tested before Pavel's certificate exists. Slice 5 can be dry-run up to notarization.

## Conflicts to clean up (rule 7)

- `agent/goal.md` M1 and rule 1 still describe the .pkg and its postinstall. Pavel's DMG decision of 21.10.26 is newer and wins. Update both in slice 2.
- `docs/re/app-architecture.md` 9 and `feature-inventory.md` F98 plan an "opt-in" updater. Pavel now asks for a daily background check, so this design checks and installs automatically by default, with an opt-out in Settings. Update the plan text in slice 4.
- #114's `linux-release.yml` triggers on `v*` and would also run on `v0.2.0-mac`. It should trigger on `v*-linux`.
- v0.1.0-mac is a pre-release. The Worker ignores pre-releases, so `/download` and the appcast start working with the first full release (v0.2.0-mac).

## Risks to verify during implementation

- **An update waiting to install when the user uninstalls.** Sparkle may install it when the app quits and put Shepetal.app back. Before quitting, the uninstall clears Sparkle's staged update in `~/Library/Caches/io.backant.shepetal/org.sparkle-project.Sparkle`. M-UNINST-3 checks it with a real staged update. If clearing it is not enough, the uninstall has to stop the waiting `Autoupdate` process.
- The System Audio Recording pane anchor and the Ask-by-tap prompt, on 14.4 and on 15.x.
- That no entitlement beyond audio-input is needed under the hardened runtime (dictation, meetings, the cleanup model, mic/camera meeting detection from #169).
- Whether `tccutil reset All io.backant.shepetal` works without root for Accessibility and Input Monitoring. If not, the step is best effort and says nothing.

## Pavel must provide

1. **Decide the team before the first release:** individual (`Pavel Hegler`, team `MZ5HWASW58`, shown as the developer in Gatekeeper dialogs) or an organization (for example backant, which needs a D-U-N-S number and gets a new Team ID). The Team ID is part of the DR. Changing it later costs every user their permissions once, and it cannot happen in the same release as an EdDSA key change.
2. **An active, paid Apple Developer Program membership** for that team ($99/year). Developer ID certificates need it, and only the Account Holder can create them.
3. **A Developer ID Application certificate.** Create it in Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application, or at developer.apple.com › Certificates. It is installed in the **login Keychain** on his Mac. Export it with its private key as a password-protected .p12, then set it with `gh secret set MAC_DEVELOPER_ID_P12 --env mac-release` (base64 of the .p12) and `MAC_DEVELOPER_ID_P12_PASSWORD`, and delete the exported file. No Developer ID **Installer** certificate is needed (no .pkg).
4. **An App Store Connect API key for notarytool.** Create it under App Store Connect › Users and Access › Integrations › Team Keys with the role Developer. Note its Key ID and Issuer ID; the .p8 can be downloaded only once. Locally, run `xcrun notarytool store-credentials shepetal-notary --key <p8> --key-id <id> --issuer <issuer>` (login Keychain). In GitHub, set `NOTARY_KEY_P8` (base64), `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` in `mac-release`. Keep the .p8 in the password manager and delete it from Downloads.
5. **The Sparkle EdDSA key**, as in 3: run `generate_keys` once (login Keychain), set `SPARKLE_ED_PRIVATE_KEY` from `generate_keys -x` with `gh secret set --env mac-release`, keep a password-manager backup, and pass on the **public** key (it is safe to share) for make-app.sh.
6. **The GitHub environment `mac-release`**, restricted to `v*-mac` tags, with Pavel as its required reviewer, and **a tag ruleset** so only he can create, move or delete `v*-mac` tags (#227; the exact steps are in PR #228). Pavel sets the secret values himself (items 3 to 5). Agents never see the files.
7. **Production deploy of the web change** (`/appcast.xml`, `/download` → DMG) to shepetal.backant.io. Optionally, a fine-grained read-only `GITHUB_TOKEN` Worker secret (`wrangler secret put GITHUB_TOKEN`).
8. **Brand:** an OK to commit the rendered DMG background (wordmark + palette) to the public repo, which is part of the open brand/ decision.
9. **Each release:** try the draft's DMG, write the notes, click **Publish release**.

The critical path for the 24.10 soft launch is items 1 to 4: enrolling a new account can take Apple a day or two, and notarization usually takes minutes. If they are not ready, the DMG can ship signed with Apple Development and not notarized. macOS 15 then sends every user to Privacy & Security › Open Anyway, and the switch to Developer ID resets permissions once more. Not recommended.
