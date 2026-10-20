#!/usr/bin/env python3
"""Compute shepetal's Wispr Flow parity from docs/parity.md (see agent/goal.md, "The finish line").

  python3 scripts/parity.py                                 check the ledger, print coverage
  python3 scripts/parity.py --completeness MAP IDENTIFIERS  also fail on unmapped Wispr identifiers
                                                            and on map entries missing from the lists
  python3 scripts/parity.py --self-test                     assert-based self-check

Exit status 1 when any rule is broken. The ledger syntax is described at the top of docs/parity.md.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLATFORMS = ("Mac", "Linux", "iPhone")
VALUES = {"done", "hand-test", "confirmed", "impossible", "n/a", "outside", "todo"}
AUTOMATED = {"done", "hand-test", "confirmed", "impossible", "n/a", "outside"}
CONFIRMED = AUTOMATED - {"hand-test"}
DESKTOP = {"M", "W"}  # inventory Wispr-column letters that map to the Mac and Linux columns (goal "Platform mapping")
NA_CATEGORIES = {"billing", "subscriptions", "referrals", "telemetry", "remote-flags", "ab-tests", "account-admin"}
# A docs/manual-test.md step id (M-FN-1, I-DICT-1, L-KEY-2, MEET-3). A cell that waits on one is hand-test, not done (#41).
HAND_STEP = re.compile(r"\b(?:[MIL]-[A-Z]+-\d+|MEET-\d+)\b")
STEP_PREFIX = {"Mac": ("M-", "MEET-"), "Linux": ("L-", "MEET-"), "iPhone": ("I-", "MEET-")}  # a hand-test cell's own steps
ROW = re.compile(r"^\|\s*(F\d+)\s*\|(.*)\|\s*$", re.M)
# A segment label is one platform or a list of them ("Mac and Linux", "Mac, Linux"), optionally followed by a
# qualifier that starts with a comma or a parenthesis ("Mac, under rule 8 (...)", "Linux (X11)").
LABEL = re.compile(r"(All|Mac|Linux|iPhone)((?:\s*,\s*|\s+and\s+|\s*&\s*)(?:Mac|Linux|iPhone)\b)*(?=$|\s*[,(])")
PLATFORM_WORD = re.compile(r"(all|mac|macos|linux|iphone|ios)\b", re.I)


def rows(text):
    for m in ROW.finditer(text):
        yield m.group(1), [c.strip() for c in m.group(2).split("|")]


def labelled(segment):
    """-> the platforms a segment's label names (see LABEL), or None for a free note."""
    label, colon, _ = segment.partition(":")
    m = LABEL.match(label.strip()) if colon else None
    if not m:
        return None
    named = re.findall(r"All|Mac|Linux|iPhone", m.group(0))
    return list(PLATFORMS) if "All" in named else named


def evidence(notes, errors=None, fid=""):
    """Map each platform to the text of the segments whose label names it. A label that starts with a
    platform-like word but does not parse ("macOS:", "Mac users:") is reported in `errors`."""
    out = dict.fromkeys(PLATFORMS, "")
    for segment in notes.split(";"):
        label, colon, body = segment.partition(":")
        named = labelled(segment)
        if named is None and colon and PLATFORM_WORD.match(label.strip()) and errors is not None:
            errors.append(f"{fid}: segment label {label.strip()[:40]!r} is not Mac, Linux, iPhone or All "
                          "(or a list of them, optionally followed by ', ...' or '(...)')")
        for p in named or []:
            out[p] += " " + body
    return out


def has_test_and_pr(e):
    """A non-blank `test name` in backticks, and a #N outside backticks that is not an issue reference."""
    outside = re.sub(r"`[^`]*`", " ", e)
    outside = re.sub(r"(?i)\bissues?\s*#\d+(?:\s*(?:,|and|&)\s*#\d+)*", " ", outside)
    return bool(re.search(r"`\s*[^`\s][^`]*`", e) and re.search(r"#\d+", outside))


def check(inventory, ledger, manual):
    """Return (errors, cell values) for a ledger against the inventory and the docs/manual-test.md text."""
    errors, ledger_ids, cells = [], set(), []
    steps = set(re.findall(r"^#+\s+(" + HAND_STEP.pattern + ")", manual, re.M))  # headings only
    wispr = {fid: set(cols[1].split()) for fid, cols in rows(inventory)}
    # A malformed Wispr column ("M,W", "") holds no desktop letter, so outside would pass silently.
    errors += [f"{fid}: inventory Wispr column must be M, W and/or i separated by spaces, got {' '.join(sorted(w))!r}"
               for fid, w in wispr.items() if not w or w - DESKTOP - {"i"}]
    for fid, cols in rows(ledger):
        if fid in ledger_ids:
            errors.append(f"{fid}: duplicate row")
            continue
        ledger_ids.add(fid)
        if len(cols) != 5:
            errors.append(f"{fid}: expected | F-ID | Feature | Mac | Linux | iPhone | Evidence / notes |")
            continue
        ev = evidence(cols[4], errors, fid)
        # Note text outside a `Mac:` / `Linux:` / `iPhone:` / `All:` label ("Mac and Linux: ...", a bare note)
        # still counts against a done cell that cites a hand step there.
        loose = " ".join(seg for seg in cols[4].split(";") if labelled(seg) is None)
        for p, value in zip(PLATFORMS, cols[1:4]):
            cells.append(value)
            e = ev[p]
            if value not in VALUES:
                errors.append(f"{fid} {p}: unknown value {value!r}")
            elif value == "done" and not has_test_and_pr(e):
                errors.append(f"{fid} {p}: done needs a `test name` and a PR number (#N)")
            elif value == "done" and HAND_STEP.search(e + " " + loose):
                errors.append(f"{fid} {p}: done cites hand step {HAND_STEP.search(e + ' ' + loose).group()}; a cell that "
                              "waits on docs/manual-test.md is hand-test")
            elif value == "hand-test" and not any(st.startswith(STEP_PREFIX[p]) for st in HAND_STEP.findall(e)):
                errors.append(f"{fid} {p}: hand-test needs a docs/manual-test.md step for {p} "
                              f"({' or '.join(x + 'XX-1' if x != 'MEET-' else 'MEET-1' for x in STEP_PREFIX[p])})")
            elif value == "hand-test" and set(HAND_STEP.findall(e)) - steps:
                errors.append(f"{fid} {p}: hand-test step(s) {sorted(set(HAND_STEP.findall(e)) - steps)} not in docs/manual-test.md")
            elif value == "impossible" and not re.search(r"https?://\S+", e):
                errors.append(f"{fid} {p}: impossible needs a doc citation (URL)")
            elif value == "n/a":
                m = re.search(r"\bn/a ([\w-]+): *\w", e)
                if not m or m.group(1) not in NA_CATEGORIES:
                    errors.append(f"{fid} {p}: n/a needs 'n/a <category>: <reason>' with a category in {sorted(NA_CATEGORIES)}")
            elif value == "outside" and (p == "iPhone" or DESKTOP & wispr.get(fid, set())):
                errors.append(f"{fid} {p}: outside needs a Mac or Linux cell whose inventory Wispr column has no M or W "
                              "(an iPhone cell is never outside; use impossible)")
    inventory_ids = set(wispr)
    errors += [f"{fid}: in the inventory but missing from the ledger" for fid in sorted(inventory_ids - ledger_ids)]
    errors += [f"{fid}: in the ledger but not in the inventory" for fid in sorted(ledger_ids - inventory_ids)]
    return errors, cells


def coverage(cells):
    """(automated %, confirmed %) over all cells."""
    n = len(cells) or 1
    return 100 * sum(v in AUTOMATED for v in cells) / n, 100 * sum(v in CONFIRMED for v in cells) / n


def completeness(map_text, identifiers, ledger_ids):
    """identifiers: {(category, name)}. Map lines: category<TAB>identifier<TAB>F-ID|internal<TAB>reason."""
    errors, mapped = [], set()
    for n, line in enumerate(map_text.splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t") + ["", ""]
        category, name, target, reason = cols[0], cols[1], cols[2], cols[3].strip()
        if (category, name) not in identifiers:
            # The map covers every identifier, so this catches truncated lists as well as stale entries.
            errors.append(f"map line {n}: {category}: {name} is not in the identifier lists")
        elif target == "internal" and not reason:
            errors.append(f"map line {n}: internal needs a reason")
        elif target != "internal" and target not in ledger_ids:
            errors.append(f"map line {n}: {target!r} is not an F-ID in the ledger")
        else:
            mapped.add((category, name))
    errors += [f"unmapped {c}: {i}" for c, i in sorted(identifiers - mapped)]
    return errors


def read_identifiers(directory):
    ids = set()
    for path in sorted(pathlib.Path(directory).glob("*-*.txt")):
        category = re.fullmatch(r"(.+)-\d+\.txt", path.name).group(1)
        ids |= {(category, line) for line in path.read_text().splitlines() if line}
    return ids


def self_test():
    inv = "| F01 | a | M | n | x | P0 | y |\n| F02 | b | M | n | x | P0 | y |\n"
    good = ("| F01 | a | done | impossible | n/a | Mac: `HotkeyTests.testHold` #3; "
            "Linux: https://www.kernel.org/doc/x; iPhone: n/a billing: store only |\n"
            "| F02 | b | hand-test | todo | confirmed | Mac, under rule 8 (never refocus): hand step M-FN-1 |\n")
    manual = "## Mac\n### M-FN-1: hold to talk\nAlso see M-FN-9 and L-KEY-1 in the text.\n### L-KEY-2: key\n### MEET-2: meeting\n"
    errors, cells = check(inv, good, manual)
    assert errors == [], errors
    assert coverage(cells) == (500 / 6, 400 / 6), coverage(cells)

    def fails(ledger, needle):
        errors = check(inv, ledger, manual)[0]
        assert any(needle in e for e in errors), (needle, errors)

    fails(good.splitlines()[0], "F02: in the inventory but missing")
    fails(good + "| F03 | c | todo | todo | todo | |\n", "F03: in the ledger but not in the inventory")
    fails(good.replace("#3", ""), "F01 Mac: done needs")
    fails(good.replace("`HotkeyTests.testHold`", "HotkeyTests.testHold"), "F01 Mac: done needs")
    fails(good.replace("https://www.kernel.org/doc/x", "the kernel forbids it"), "F01 Linux: impossible needs")
    fails(good.replace("n/a billing", "n/a cloud-sync"), "F01 iPhone: n/a needs")
    fails(good.replace("Mac: `HotkeyTests", "Linux: `HotkeyTests"), "F01 Mac: done needs")  # no cross-platform evidence
    fails(good.replace("n/a billing: store only", "n/a billing"), "F01 iPhone: n/a needs")
    fails(good.replace("| todo |", "| wip |"), "unknown value 'wip'")
    # #102: hand-test needs its own platform's step, present as a docs/manual-test.md heading.
    fails(good.replace("hand step M-FN-1", "hand step pending"), "F02 Mac: hand-test needs")
    fails(good.replace("M-FN-1 |", "M-NOPE-9 |"), "['M-NOPE-9'] not in docs/manual-test.md")
    fails(good.replace("M-FN-1 |", "M-FN-9 |"), "['M-FN-9'] not in docs/manual-test.md")  # body text is no step
    fails(good.replace("M-FN-1 |", "L-KEY-2 |"), "F02 Mac: hand-test needs")  # another platform's step
    assert check(inv, good.replace("M-FN-1 |", "MEET-2 |"), manual)[0] == []
    fails(good.replace("Mac, under rule 8 (never refocus):", "Linux:"), "F02 Mac: hand-test needs")
    fails(good.replace("Mac, under rule 8 (never refocus):", "") , "F02 Mac: hand-test needs")  # a free note
    # Label lists route to every platform they name; prose after a platform word is an error, not evidence.
    both = good.replace("| hand-test | todo |", "| hand-test | hand-test |").replace(
        "Mac, under rule 8 (never refocus): hand step M-FN-1", "Mac and Linux: hand steps M-FN-1, L-KEY-2")
    assert check(inv, both, manual)[0] == [], check(inv, both, manual)[0]
    assert check(inv, both.replace("Mac and Linux:", "Mac, Linux (X11):"), manual)[0] == []
    fails(both.replace("Mac and Linux:", "Mac:"), "F02 Linux: hand-test needs")
    for label in ("macOS", "iOS", "Mac users", "Mac/Linux", "Linux port is blocked"):
        fails(good.replace("Mac, under rule 8 (never refocus)", label), f"F02: segment label {label!r}")
    assert check(inv, good.replace("Mac: `HotkeyTests.testHold` #3", "All: `HotkeyTests.testHold` #3"), manual)[0] == []
    fails(good.replace("Mac: `HotkeyTests.testHold` #3", "`HotkeyTests.testHold` #3"), "F01 Mac: done needs")
    # done: a real test name and a #N that is the PR, outside the backticks.
    for bad in ("` ` #3", "`run #3`", "`T` issue #3", "`T` Issue #3", "`T` issue#3", "`T` issues #2 and #3", "`T` see issues #3"):
        fails(good.replace("`HotkeyTests.testHold` #3", bad), "F01 Mac: done needs")
    # A labelled step (here F02's Mac qualifier segment) is not loose text against another column's done cell.
    linux_done = good.replace("| hand-test | todo | confirmed |", "| hand-test | done | confirmed |").replace(
        "hand step M-FN-1 |", "hand step M-FN-1; Linux: `GestureTests.hold` #4 |")
    assert check(inv, linux_done, manual)[0] == [], check(inv, linux_done, manual)[0]
    # The structural rules each fail on their own.
    fails(good + good.splitlines()[1] + "\n", "F02: duplicate row")
    fails(good.replace("| F02 | b | hand-test |", "| F02 | b |"), "F02: expected")

    for step in ("M-NS-1", "I-DICT-1", "L-KEY-2", "MEET-3"):  # done may not wait on a hand step (#41)
        fails(good.replace("#3;", f"#3, see {step};"), f"F01 Mac: done cites hand step {step}")
    fails(good.replace("#3;", "#3; waits on M-NS-1;"), "F01 Mac: done cites hand step M-NS-1")  # unlabelled note
    fails(good.replace("#3;", "#3; Mac and Linux: hand step M-FN-1;"), "F01 Mac: done cites hand step M-FN-1")
    for text in ("UTF-8", "SHA-256", "F01-2"):  # look-alikes that are not step ids
        assert check(inv, good.replace("#3;", f"#3 {text};"), manual)[0] == [], text

    # outside: only for a column the feature's Wispr platforms don't map to.
    ios_inv = inv + "| F09 | k | i | y | x | P2 | y |\n"
    ios = good + "| F09 | k | outside | outside | todo | |\n"
    errors, cells = check(ios_inv, ios, manual)
    assert errors == [], errors
    assert coverage(cells[-3:]) == (200 / 3, 200 / 3), coverage(cells[-3:])
    fails(good.replace("| hand-test |", "| outside |"), "F02 Mac: outside needs")  # Wispr ships it on Mac
    for wispr in ("M", "W", "M W i"):  # any desktop letter keeps Mac and Linux inside the mapping
        errors = check(ios_inv.replace("| k | i |", f"| k | {wispr} |"), ios, manual)[0]
        assert any("F09 Mac: outside needs" in e for e in errors), (wispr, errors)
        assert any("F09 Linux: outside needs" in e for e in errors), (wispr, errors)
    for wispr in ("M,W", "MW", "", "mac win"):  # a malformed column must not let outside through
        errors = check(ios_inv.replace("| k | i |", f"| k | {wispr} |"), ios, manual)[0]
        assert any("F09: inventory Wispr column must be" in e for e in errors), (wispr, errors)
    errors = check(ios_inv, ios.replace("| todo | |", "| outside | |"), manual)[0]
    assert any("F09 iPhone: outside needs" in e for e in errors), errors

    ids = {("flags", "x-flag"), ("events", "y_event")}
    full = "flags\tx-flag\tF01\nevents\ty_event\tinternal\tserver-side metric\n"
    assert completeness(full, ids, {"F01"}) == []
    assert completeness(full.splitlines()[0], ids, {"F01"}) == ["unmapped events: y_event"]
    assert completeness(full, {("flags", "x-flag")}, {"F01"}) == ["map line 2: events: y_event is not in the identifier lists"]
    assert any("internal needs a reason" in e for e in completeness(full.replace("\tserver-side metric", ""), ids, {"F01"}))
    assert any("not an F-ID" in e for e in completeness(full, ids, {"F02"}))
    print("self-test ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--completeness", nargs=2, metavar=("MAP", "IDENTIFIERS_DIR"))
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    ledger = (ROOT / "docs/parity.md").read_text()
    errors, cells = check((ROOT / "docs/re/feature-inventory.md").read_text(), ledger,
                          (ROOT / "docs/manual-test.md").read_text())
    if args.completeness:
        map_path, ids_dir = args.completeness
        ids = read_identifiers(ids_dir)
        if not ids:
            errors.append(f"no identifiers found in {ids_dir}")
        errors += completeness(pathlib.Path(map_path).read_text(), ids, {fid for fid, _ in rows(ledger)})
    for e in errors:
        print("FAIL", e)
    auto, conf = coverage(cells)
    print(f"automated coverage: {auto:.1f}% of {len(cells)} cells")
    print(f"confirmed coverage: {conf:.1f}% of {len(cells)} cells")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
