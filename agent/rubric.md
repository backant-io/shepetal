# shepetal parity rubric

Grade the agent's latest report. Each criterion needs evidence pasted in the report: a command and its real output, or a PR or issue link.

- `python3 scripts/parity.py`, run on a fresh clone of origin/main, reports 100% automated coverage. Its output is pasted.
- `python3 scripts/parity.py --completeness /Users/sorcecoder/shepetal-re/identifier-map.tsv /Users/sorcecoder/shepetal-re/identifiers` passes, so every Wispr Flow identifier maps to a feature or to `internal` with a reason.
- `./scripts/ci/run-checks.sh` passes on a fresh clone of origin/main (or the reason a suite can't run there is stated), and the latest GitHub Actions run on main is green. Both results are pasted.
- Every PR merged since the previous report has an independent review in its body or comments: who reviewed it, the commands run, and the deliberate-break results.
- `git log origin/main` shows no Co-Authored-By line and no mention of Claude or AI in any commit message added since the previous report.
- docs/progress.md has a section for every iteration of this session listing done / verified / left / blocked, and it matches the merged PRs.
- docs/parity.md never marks a cell `done` without a named test and a PR, and never writes `confirmed`, which only Pavel writes.
- Every `hand-test` cell has exact steps in docs/manual-test.md.
- The report states that no test or check touched Pavel's clipboard, took focus, or showed a window outside the UI lock.
- Every product rule in agent/goal.md is honored in the merged code. In particular: fn starts recording; a too-short press is ignored with a hint; the tiny 🤫 sits bottom-left; raw audio of every recording is kept; models are local only; the summarizer is not an LLM; paste only into the window that stayed in focus, otherwise the text goes to the clipboard.
