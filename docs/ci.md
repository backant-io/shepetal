# CI (#21)

`scripts/ci/run-checks.sh` runs every test suite in the repo and stops at the first failure. Run it before every push.

| Suite | What it runs |
|---|---|
| `swift` | `swift build && swift test` at the repo root (the Mac app core) |
| `meeting` | `swift build && swift test` in `meeting/` |
| `ios` | `xcodegen generate`, then `xcodebuild build test` on the first installed iPhone simulator (`IOS_SIMULATOR` picks another) |
| `summarize` | `python -m unittest` in `summarize/`, in a local venv with numpy |
| `bench` | `bench/test_bench.py` through `uv` with jiwer |
| `scripts` | `parity.py` and its self-test, the `extract_identifiers.py` and `check_re_docs.py` self-tests, `check_re_docs.py`, `parity.py --completeness`, and `run-checks.sh --self-test` |
| `linux` | `cargo test`, `cargo build --release` and a `probe` run in Docker `ubuntu:24.04`, as in `linux/README.md`. Prints `linux/: not on this branch` and passes while `linux/` is missing |
| `meeting-linux` | MeetingCore's tests in Docker `swift:6.2` |

```bash
scripts/ci/run-checks.sh              # all suites
scripts/ci/run-checks.sh --fast       # skip ios, linux and meeting-linux
scripts/ci/run-checks.sh --only ios   # one suite
scripts/ci/run-checks.sh --self-test  # check the runner itself
```

Tools it needs on PATH: `swift` and Xcode, `xcodegen` (ios), `python3` (summarize, scripts), `uv` (bench; often in `~/.local/bin`), and Docker (linux, meeting-linux). A missing tool fails its suite loudly (for example `uv: command not found`, exit 127).

Build caches (Docker targets, the iOS DerivedData) go to `.cache/ci/` (gitignored), or to `CI_CACHE` if set. Delete that folder to free disk.

`--self-test` checks that a suite whose middle command fails stops the run with exit 1, that the suites after it do not run, and that every suite has its own `--only` step in the workflow. It is the last command of the `scripts` suite.

## GitHub Actions

`.github/workflows/ci.yml` runs the same suites, one step per suite, on every pull request and every push to main:
- a `macos-26` job (Xcode 26.3, Swift 6.2): `swift`, `meeting`, `ios`, `summarize`, `bench`, `scripts`;
- an `ubuntu-24.04` job: `linux` and `meeting-linux` through Docker.

## Not run in CI

- `scripts/e2e-mac.sh` needs the 470 MB Parakeet v3 model, so `ci.yml` and `run-checks.sh` do not run it. The Claims workflow
  (`.github/workflows/claims.yml`, see [claims.md](claims.md)) runs it with the network denied, with `CLEANUP=rules`,
  `LANGUAGES=skip` and `LATENCY=report` (ready times reported, held to 2000 ms instead of 700), together with `scripts/e2e-meeting.sh`. Run the full script by hand before a change to the Mac pipeline lands.
- The copied-Wispr-string check in `check_re_docs.py` and `parity.py --completeness` need `/Users/sorcecoder/shepetal-re/`, which is only on Pavel's Mac. CI runs `check_re_docs.py --no-bundle` and skips `--completeness` with a `SKIP` line. `run-checks.sh` runs both in full when that folder exists.
