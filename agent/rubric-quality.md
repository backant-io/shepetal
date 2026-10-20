# shepetal quality rubric

Grade the quality session's latest report. Every criterion needs pasted evidence: a command and its real output, or a PR or issue link.

- The latest GitHub Actions run on main is green, and `./scripts/ci/run-checks.sh` passes on a fresh clone of origin/main. Any red run since the previous report was fixed or has an issue naming the cause.
- Every PR merged to main since the previous report was reviewed after the fact, with the commands run and deliberate-break checks on its key logic. Each finding has an issue with evidence, or a fix PR.
- The report lists dead code, duplicate helpers, unused dependencies or speculative abstractions that were removed, each through its own small PR with an independent review and green tests. Or it says none were found, with the searches used.
- docs/parity.md has no `done` cell without a named test and a PR, and no `confirmed` cell written by anyone but Pavel. Any wrong cell was corrected.
- No test on main touches Pavel's clipboard, takes focus, or shows a window outside the UI lock. The search used to check this is pasted.
- No quality PR edited a file that another session's open PR was changing.
- Every commit follows the git rules: no Co-Authored-By line, and no mention of Claude or AI.
