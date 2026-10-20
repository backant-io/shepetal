# Quality report

The quality session keeps main green, re-reviews merged PRs after the fact, and removes dead weight. This file holds its latest report, and the newest section comes first. Every claim has the command that produced it, or a PR or issue link.

Scripts used (scratch, outside the repo): `~/shepetal-agent/tmp/quality-main/check.sh [ref]` checks out the ref in the reused worktree `~/shepetal-agent/wt/quality-main`, runs the steps below and prints `RESULT <sha> ok|FAILED:<step>`:
- `swift build -j 4`
- `swift test -j 4`
- `swift build -c release -j 4`
- `sandbox-exec -p '(version 1)(allow default)(deny network*)' scripts/e2e-mac.sh`
- `python3 scripts/parity.py`
- `python3 scripts/check_re_docs.py`
- `python3 -m unittest agent/test_run.py`

`SHEPETAL_HOME` points at `~/shepetal-agent/home/quality-main`, and the e2e uses its own `.cache/e2e/home`.

## Report 1: 2026-10-20, 21:40 to 22:40 CEST, main at 929cb78

### 1. main is green after every merge

| main after | merged | `swift test` | e2e (network denied) | parity.py | result |
|---|---|---|---|---|---|
| c454edb | #51 (baseline) | 35 tests, 0 failures | WER 0.0% over 6 clips, ready 61–130 ms, paste-not-landed OK | 6.5% / 4.8% | ok |
| 2a4ba42 | #52 | 35 tests, 0 failures | WER 0.0%, OK | 6.5% / 4.8% | `RESULT 2a4ba42 ok` |
| f099168 | #40, #36 | 46 tests, 0 failures | WER 0.0%, OK | 7.0% / 4.8% | `RESULT f099168 ok` |
| a3a6f0c | #2 (linux/ only) | 46 tests, 0 failures | WER 0.0%, OK | 7.0% / 4.8% | `RESULT a3a6f0c ok` |
| 929cb78 | #64 (.gitignore only) | `swift build` ok, agent test OK | not re-run: the tree differs from a3a6f0c only in `.gitignore` | 7.0% / 4.8% | ok |

`python3 scripts/parity.py --completeness /Users/sorcecoder/shepetal-re/identifier-map.tsv /Users/sorcecoder/shepetal-re/identifiers` exits 0 on 929cb78. `python3 scripts/check_re_docs.py` gives `9 docs, 111 quoted prose spans, 124 inventory rows: ok`.

**CI: main has no GitHub Actions run, because main has no workflow.** `gh run list --branch main` is empty. On main, `.github/` holds only `FUNDING.yml`, and `scripts/ci/run-checks.sh` does not exist. The cause is tracked in #21, and the fix is PR #25 (chore/ci, owned by another session, still open). Its own runs on the PR branch are green. Until #25 lands, the table above is the only gate on main.

### 2. Post-merge review of merged PRs

Each row says what was run on main and which deliberate breaks were made. Every break was reverted afterwards, and `git status` was clean.

| PR | What was checked | Breaks | Findings |
|---|---|---|---|
| #52 run.py install race (quality) | fresh clone, `python3 -m unittest agent/test_run.py` (5 OK). An audit hook showed that no process is spawned. Independent review in the [PR comment](https://github.com/backant-io/shepetal/pull/52#issuecomment-6300069861) | 6 breaks (wait loop, retry, deadline exit, final exit, both), all caught | none open |
| #64 ignore `__pycache__` (quality) | fresh clone; review in the [PR comment](https://github.com/backant-io/shepetal/pull/64#issuecomment-6300618831) | reverting the line makes `agent/__pycache__/` untracked again: caught | none |
| #36 Mac hub and history | `swift test --filter HistoryTests` on main | 8 breaks in `Sources/ShepetalCore/History.swift`. Caught: raw URL stored instead of `Browser.historyURL`, query kept, `;path-params` kept, migrations re-run from 0, LIKE wildcards not escaped, archived rows not hidden, `update` hitting every row. Not caught: `sqlite3_busy_timeout(db, 0)` (minor, a timing path) | none new; #38 already lists the hub UI test gap |
| #40 summarizer action items | `cd summarize && python3 -m venv .venv && .venv/bin/pip install numpy && .venv/bin/python -m unittest`: 36 tests OK, 6 skipped (the AMI test split needs the corpus) | 6 breaks in `summarize.py`, all caught: questions as commitments, classifier threshold, first-person owner, addressee fallback, repeated-task dedupe, sigmoid sign | none new; #8 (80% goal not met) stays open |
| #10 + #35 Mac foundation, hermetic e2e | full `check.sh` on main (above) | 12 breaks in ShepetalCore, all caught: hold threshold 0.5→0.3, `<`→`<=` at the threshold, double-tap window, chord window, hint duration, too-short and cancelled audio not kept, audio file 0644, audio dir 0755, 24 h cutoff off by 1 h, PasteCheck counting a read before Cmd+V, failAfter 1→3 s | none new; rule 8 (#42) and the shell-path tests (#15, PR #28) are already tracked |
| #1 meeting detection | fresh clone: `cd meeting && swift test` (17 passed), swift:6.2 Docker (14 MeetingCore passed) | 37 mutations: 28 caught, 9 not | **#61** (bug: one call during back-to-back calendar events starts two meetings, reproduced with a scratch test), **#62** (test gaps: Core Audio mic-holder probe untested, self bundle-ID rule untested, `endWithEvidence` never takes effect, stale comments) |
| #7 parity.py | `--self-test` ok; on a copy of docs/parity.md | caught (exit 1): `done` without evidence, `done` with a PR but no test, missing inventory row, `n/a` outside the allowed categories. **Not caught: a `confirmed` cell** (exit 0) | parity.py cannot tell who wrote a cell, so the guard is the audit in section 4: no commit on main adds `confirmed` |

**Not yet re-reviewed** (left for the next report): #3 (ios/; the ios session builds it), #4 and #5 (bench/, the first summarizer version), #2 (linux/; needs the Docker build), #6, #23 and #48–#51 (docs and agent tooling; read-only checks only).

### 3. Lean and clean

- Removed: **#64**, the stale `bench/__pycache__/` ignore. It now covers every directory, because #52's test left `agent/__pycache__/` untracked. Independently reviewed, merged.
- Found but not removed, because their owners have open work in the same files: in `meeting/`, an inert `endWithEvidence` default, a `"shepetal"` selfBundleIDs entry that matches no bundle ID, two public mutating funcs that only `update()` calls, and two stale comments (all listed in #62).
- Searches used: `grep -rn` for each symbol across the repo, plus the mutation runs above. A symbol that no test, caller or doc uses is a candidate.

### 4. Ledger audit (docs/parity.md on 929cb78)

```
$ python3 scripts/parity.py
automated coverage: 7.0% of 372 cells
confirmed coverage: 4.8% of 372 cells
$ awk -F'|' '/^\| F/ {for(i=4;i<=6;i++){gsub(/ /,"",$i); if($i=="done"||$i=="confirmed") print $2, i, $i}}' docs/parity.md
(no output: no done and no confirmed cell)
$ for s in $(grep -oE 'M-[A-Z]+-[0-9]+' docs/parity.md | sort -u); do grep -q "### $s" docs/manual-test.md || echo MISSING $s; done
(no output: every hand-test step exists)
$ for t in $(grep -oE '`[A-Za-z]+Tests\.test[A-Za-z0-9_]+`' docs/parity.md | tr -d '`' | sort -u); do grep -rqs "func ${t#*.}" Tests ios meeting linux || echo MISSING $t; done
MISSING HotkeyTests.testHoldStartsRecording      <- the format example in the legend (line 11), not a cell
```

No cell needed a correction.

### 5. Nothing touches Pavel's clipboard, focus or screen

```
$ grep -rnE "NSPasteboard\.general|UIPasteboard\.general|pbcopy|pbpaste|\.activate\(|makeKeyAndOrderFront|orderFront|NSApp\.activate|makeKeyWindow" Tests ios/Tests meeting/Tests scripts bench summarize linux/src
(hits only in summarize/.venv/…/pip/_vendor, the gitignored third-party venv; none in repo files)
```

`.general`, `orderFrontRegardless` and `NSApp.activate` appear only in app code (`Sources/Shepetal/App.swift`, `Indicator.swift`), not in tests. The e2e asserts a private `io.backant.shepetal.e2e.*` pasteboard and `window_visible == false` on every clip. No check in this report launched the app, took focus or showed a window. All of them used a scratch `SHEPETAL_HOME`.

### 6. No quality PR edited a file another session's open PR was changing

Quality PRs touched `agent/run.py`, `agent/test_run.py` (#52) and `.gitignore` (#64). Before each one, and again now, the check was:
```
$ for n in $(gh pr list --json number --jq '.[].number'); do gh pr diff $n --name-only | grep -E "^(agent/run.py|agent/test_run.py|\.gitignore|docs/quality.md)$"; done
(no output)
```

### 7. Git rules

```
$ git log origin/main --format='%h %s%n%b' | grep -icE "co-authored|claude|anthropic|\bAI\b|generated with"
0
```

### Next

- Run `check.sh` after every merge to main, including the release PR #53, the Mac feature PRs #28, #34, #39, #44 and #47, and CI #25. Once #25 lands, also run `scripts/ci/run-checks.sh` from a fresh clone and check the Actions run on main.
- Re-review the PRs listed above as not yet re-reviewed.
- After 00:00, do lean-and-clean on main: dead code, duplicate helpers, unused dependencies, one small PR each.
