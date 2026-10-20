# Wispr Flow reverse-engineering notes

Behavior notes on Wispr Flow 1.6.1174, read statically under the rules in `agent/goal.md`: learn behavior only, cite evidence as path + symbol or offset, and paraphrase. Start with `feature-inventory.md`.

## Check

```sh
python3 scripts/check_re_docs.py --self-test
python3 scripts/check_re_docs.py
```

The second command reads the extracted Wispr bundle under `/Users/sorcecoder/shepetal-re/` and the installed app's `ax-inspect*.mjs`, so it runs on Pavel's Mac. It fails on a quoted Wispr log string, a Wispr backend endpoint, or an inventory row that is neither P0, P1, P2 nor an n/a in a category the goal allows.
