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
VALUES = {"done", "hand-test", "confirmed", "impossible", "n/a", "todo"}
AUTOMATED = {"done", "hand-test", "confirmed", "impossible", "n/a"}
CONFIRMED = AUTOMATED - {"hand-test"}
NA_CATEGORIES = {"billing", "subscriptions", "referrals", "telemetry", "remote-flags", "ab-tests", "account-admin"}
ROW = re.compile(r"^\|\s*(F\d+)\s*\|(.*)\|\s*$", re.M)
# A segment label is one platform or a list of them ("Mac and Linux", "Mac, Linux"), optionally followed by
# a qualifier after a comma, space or parenthesis ("Mac, under rule 8 (...)", "Linux (X11)").
LABEL = re.compile(r"(All|Mac|Linux|iPhone)((?:\s*,\s*|\s+and\s+|\s*&\s*)(?:Mac|Linux|iPhone)\b)*(?=$|[\s,(])")
PLATFORM_WORD = re.compile(r"(all|mac|macos|linux|iphone|ios)\b", re.I)
STEP = re.compile(r"\b[A-Z]-[A-Z0-9]+-\d+\b")  # docs/manual-test.md step IDs: M-FN-1, I-KB-2, L-SETUP-1


def rows(text):
    for m in ROW.finditer(text):
        yield m.group(1), [c.strip() for c in m.group(2).split("|")]


def evidence(notes, errors=None, fid=""):
    """Map each platform to the text of its `Mac:` / `Linux:` / `iPhone:` / `All:` segments (see LABEL).
    A label that starts with a platform-like word but does not parse is reported in `errors`."""
    out = dict.fromkeys(PLATFORMS, "")
    for segment in notes.split(";"):
        label, colon, body = segment.partition(":")
        label = label.strip()
        m = LABEL.match(label) if colon else None
        if not m:
            if colon and PLATFORM_WORD.match(label) and errors is not None:
                errors.append(f"{fid}: segment label {label[:40]!r} is not Mac, Linux, iPhone or All (or a list of them)")
            continue
        named = re.findall(r"All|Mac|Linux|iPhone", m.group(0))
        for p in PLATFORMS if "All" in named else named:
            out[p] += " " + body
    return out


def has_test_and_pr(e):
    """A non-blank `test name` in backticks, and a #N outside backticks that is not an issue reference."""
    outside = re.sub(r"`[^`]*`", " ", e)
    return bool(re.search(r"`\s*[^`\s][^`]*`", e) and re.search(r"(?<!issue )(?<!issues )#\d+", outside))


def check(inventory, ledger, manual):
    """Return (errors, cell values) for a ledger against the inventory and the docs/manual-test.md text."""
    steps = set(re.findall(r"^#+\s+(" + STEP.pattern + ")", manual, re.M))
    errors, ledger_ids, cells = [], set(), []
    for fid, cols in rows(ledger):
        if fid in ledger_ids:
            errors.append(f"{fid}: duplicate row")
            continue
        ledger_ids.add(fid)
        if len(cols) != 5:
            errors.append(f"{fid}: expected | F-ID | Feature | Mac | Linux | iPhone | Evidence / notes |")
            continue
        ev = evidence(cols[4], errors, fid)
        for p, value in zip(PLATFORMS, cols[1:4]):
            cells.append(value)
            e = ev[p]
            if value not in VALUES:
                errors.append(f"{fid} {p}: unknown value {value!r}")
            elif value == "done" and not has_test_and_pr(e):
                errors.append(f"{fid} {p}: done needs a `test name` and a PR number (#N)")
            elif value == "hand-test" and not STEP.search(e):
                errors.append(f"{fid} {p}: hand-test needs a docs/manual-test.md step (M-XX-1, I-XX-1, L-XX-1)")
            elif value == "hand-test" and set(STEP.findall(e)) - steps:
                errors.append(f"{fid} {p}: hand-test step(s) {sorted(set(STEP.findall(e)) - steps)} not in docs/manual-test.md")
            elif value == "impossible" and not re.search(r"https?://\S+", e):
                errors.append(f"{fid} {p}: impossible needs a doc citation (URL)")
            elif value == "n/a":
                m = re.search(r"\bn/a ([\w-]+): *\w", e)
                if not m or m.group(1) not in NA_CATEGORIES:
                    errors.append(f"{fid} {p}: n/a needs 'n/a <category>: <reason>' with a category in {sorted(NA_CATEGORIES)}")
    inventory_ids = {fid for fid, _ in rows(inventory)}
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
    manual = "## Mac\n### M-FN-1: hold to talk\n"
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
    fails(good + good.splitlines()[1] + "\n", "F02: duplicate row")
    fails(good.replace("| F02 | b | hand-test |", "| F02 | b |"), "F02: expected")
    fails(good.replace("Mac: `HotkeyTests.testHold` #3", "`HotkeyTests.testHold` #3"), "F01 Mac: done needs")
    assert check(inv, good.replace("Mac: `HotkeyTests.testHold` #3", "All: `HotkeyTests.testHold` #3"), manual)[0] == []
    assert check(inv, good.replace("Mac: `HotkeyTests", "Mac and Linux: `HotkeyTests").replace("Linux: https", "https"), manual)[0] == \
        ["F01 Linux: impossible needs a doc citation (URL)"]  # "Mac and Linux" feeds both columns
    fails(good.replace("`HotkeyTests.testHold`", "` `"), "F01 Mac: done needs")
    fails(good.replace("`HotkeyTests.testHold` #3", "`run #3`"), "F01 Mac: done needs")
    fails(good.replace("#3", "see issue #3"), "F01 Mac: done needs")
    fails(good.replace("hand step M-FN-1", "hand step pending"), "F02 Mac: hand-test needs")
    fails(good.replace("M-FN-1 |", "M-NOPE-9 |"), "['M-NOPE-9'] not in docs/manual-test.md")
    fails(good.replace("Mac, under rule 8 (never refocus):", "Linux:"), "F02 Mac: hand-test needs")  # the qualifier label counted
    fails(good.replace("Mac: `Hotkey", "macOS: `Hotkey"), "F01: segment label 'macOS'")

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
