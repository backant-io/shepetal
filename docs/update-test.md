# The update test: Sparkle on a clean Mac

`.github/workflows/update.yml` (job "Update") runs on a fresh GitHub macOS runner (macos-26, a VM with no Shepetal,
no preferences and no Sparkle caches) on every PR or push to main that touches `Sources/`, `scripts/mac/`,
`scripts/make-*.sh`, `Package.*` or the workflow, every Monday, and by hand. It needs no secret. It replaces the
"bad signature" step of `docs/manual-test.md` for goal gate 2, and the update half of `docs/install-and-update.md`'s
Tests section, wherever a real person and a real Developer ID are not the point.

## What it does

`scripts/mac/update-test.sh <sparkle-dir>` (refuses to run unless `CI=true`: it resets io.backant.shepetal's
preferences):

1. A throwaway Sparkle EdDSA key, made in the job by `scripts/mac/verify-update.swift --throwaway-key` (the same
   throwaway key release.sh's dry run uses; Sparkle's `generate_keys` only writes to a keychain). The script fails if
   it is the release key.
2. Version N (0.0.1, build = commit count) with `scripts/make-app.sh`, then N+1 (0.0.2, build + 1) as a DMG with
   `scripts/make-dmg.sh`. Both are signed ad-hoc and require sign-in like a release, and both point SUFeedURL at
   `http://127.0.0.1:8765/appcast.xml`.
3. The appcast for N+1 with Sparkle's `generate_appcast` and the same flags as `scripts/mac/release.sh`; Sparkle's
   `sign_update` must produce the same signature and length (EdDSA is deterministic), and
   `verify-update.swift` checks it against the key inside the built app. `python3 -m http.server` serves the feed and
   the DMG at `download/<v>/`, the layout of the site.
4. N goes into a temp Applications folder; Sparkle's own `sparkle-cli` (`sparkle.app` from the pinned Sparkle 2.10.0
   release tarball) runs non-interactively against that bundle. Passes when the installed app is build N+1, version
   0.0.2, the DMG came from the local feed, and `codesign --verify --deep --strict` accepts it.
5. N again, and the served DMG replaced by a copy with one byte flipped (same length, same appcast, same signature).
   Passes when the DMG was downloaded, sparkle-cli printed a signature error and N is still installed.
6. N again, the good DMG, and an appcast that says build N-1. Passes when the DMG was never downloaded and N is still
   installed.

`scripts/mac/live-chain.sh` then checks the published release, read-only, with a user agent that says "bot" so the
site does not count a download: `https://shepetal.app/download` must end at `/download/<v>/Shepetal-<v>.dmg`, that
file's sha256 must match the `.sha256` next to it, `/appcast.xml` must offer that URL with that length and that build,
and its EdDSA signature must match the DMG under the SUPublicEDKey inside the DMG's own app. It prints `codesign -dv`,
`spctl -a -vv` and `stapler validate` for the record and never fails on them: Gatekeeper refuses the release because it
is not notarized, on purpose (Pavel's decision).

## The test-only overrides

`scripts/make-app.sh` takes `SHEPETAL_TEST_FEED_URL` (only `http://127.0.0.1:<port>/appcast.xml`, never with `--zip`)
and `SHEPETAL_TEST_BUILD` (only together with the feed override). `scripts/mac/release.sh` unsets both, so the release,
its dry run and CI's unsigned build never see them; mac-release.yml's verify job still refuses any SUFeedURL that is
not `https://<domain>/appcast.xml`, and the workflow's first step checks that make-app.sh refuses each misuse. A release
build keeps the real SUFeedURL and the SUPublicEDKey committed in make-app.sh.

## What it proves

- Sparkle 2.10.0, as the app embeds it, takes an installed Shepetal from N to N+1 out of the DMG `make-dmg.sh`
  builds, with the appcast written the way `release.sh` writes it.
- A DMG whose bytes do not match the appcast's EdDSA signature is refused before anything is installed.
- An appcast offering a lower build installs nothing.
- The live chain holds today: /download, the .sha256, the appcast's URL, length, build and signature, and the key
  inside the released app agree.

## What it does not prove

- Notarization and Gatekeeper on first open: the test builds are ad-hoc, the release is not notarized, and spctl's
  verdict is only printed.
- Developer ID signing, the pinned designated requirement and whether permissions (Microphone, Input Monitoring,
  Accessibility) survive an update: an ad-hoc build has a different designated requirement each time, and a runner has
  no real user to grant permissions.
- The app's own update UI, the scheduled background check, relaunch after an update and a running app being replaced:
  sparkle-cli drives Sparkle from outside the app, on a bundle that is not running.
- A real download over HTTPS from the site to Sparkle: the update comes from 127.0.0.1 over plain HTTP. The live
  chain checks the published files, but nothing installs them.
- The real Sparkle private key: it is never in this job.

Those stay manual steps in `docs/manual-test.md`.
