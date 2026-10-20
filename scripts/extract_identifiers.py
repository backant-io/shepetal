#!/usr/bin/env python3
"""Extract Wispr Flow identifiers for the parity completeness check.

Run with `python3 -I scripts/extract_identifiers.py [ASAR] [OUT]`, or `--self-test`.
Reads the pre-extracted bundle (default /Users/sorcecoder/shepetal-re/asar) and
writes <category>-<n>.txt chunks (at most 250 names each, one per line) to OUT
(default /Users/sorcecoder/shepetal-re/identifiers). OUT must be outside this
repo: the lists are Wispr's strings and are never committed.
Where each category lives is described in docs/re/app-architecture.md.
"""
import json
import pathlib
import re
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
CHUNK = 250
ENUM = re.compile(r'function\(e\)\{return e\.\w+="')


def enum_with(js, anchors):
    """Values of the one string enum in js that contains every anchor value."""
    found = []
    for m in ENUM.finditer(js):
        values = re.findall(r'e\.\w+="([^"]*)"', js[m.start():js.find(",e}(", m.start())])
        if set(anchors) <= set(values):
            found.append(values)
    assert len(found) == 1, f"expected one enum with {anchors}, found {len(found)}"
    return found[0]


def typemap(js, name):
    start = js.index(name + ":L([")
    return re.findall(r'\{json:"([^"]+)"', js[start:js.index("],!1)", start)])


def object_keys(js, start):
    """Top-level keys of the object literal whose `{` is at js[start]."""
    keys, depth, key_start, i = [], 0, None, start
    while True:
        c = js[i]
        if c in "\"'`":
            i += 1
            while js[i] != c:
                i += 2 if js[i] == "\\" else 1
        elif c in "{[(":
            depth += 1
            if depth == 1:
                key_start = i + 1
        elif c in "}])":
            depth -= 1
            if depth == 0:
                return keys
        elif depth == 1 and c == ",":
            key_start = i + 1
        elif depth == 1 and c == ":" and key_start is not None:
            key = js[key_start:i].strip().strip('"')
            if re.fullmatch(r"[\w$]+", key):
                keys.append(key)
            key_start = None  # the rest up to the next comma is the value
        i += 1


def settings_keys(js, config):
    """prefs.user defaults in the bundle, plus key names (never values) of the live config.json."""
    if not config.exists():
        sys.exit(f"missing {config}: the settings keys that exist only there would be dropped")
    keys = object_keys(js, js.index("this.user={") + len("this.user="))
    return keys + sorted(set(json.loads(config.read_text())["prefs"]["user"]) - set(keys))


def extract(asar):
    js = (asar / ".webpack/main/index.js").read_text(encoding="utf-8", errors="replace")
    renderer = asar / ".webpack/renderer"
    return {
        "settings": settings_keys(js, pathlib.Path.home() / "Library/Application Support/Wispr Flow/config.json"),
        "helper-requests": typemap(js, "HelperAPIRequest"),
        "helper-responses": typemap(js, "HelperAPIResponse"),
        "flags": enum_with(js, ["stream-text"]),
        "events": enum_with(js, ["paste_text_outcome"]),
        "windows": sorted(p.parent.name for p in renderer.glob("*/index.html")),
        "shortcut-actions": enum_with(js, ["ptt", "popo", "dismiss"]),
    }


def self_test():
    js = 'x;this.user={a:1,"b":{c:2},d:[3,4]};'
    with tempfile.TemporaryDirectory() as tmp:
        config = pathlib.Path(tmp) / "config.json"
        try:
            settings_keys(js, config)
            raise AssertionError("a missing config.json must fail, not drop its keys")
        except SystemExit as e:
            assert "missing" in str(e.code), e.code
        config.write_text(json.dumps({"prefs": {"user": {"a": 0, "z": 0}}}))
        assert settings_keys(js, config) == ["a", "b", "d", "z"], settings_keys(js, config)
    print("self-test ok")


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    asar = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/Users/sorcecoder/shepetal-re/asar")
    out = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "/Users/sorcecoder/shepetal-re/identifiers").resolve()
    if out == REPO or REPO in out.parents:
        sys.exit(f"refusing to write identifier lists inside the repo: {out}")
    out.mkdir(parents=True, exist_ok=True)
    for category, names in extract(asar).items():
        names = list(dict.fromkeys(names))
        for old in out.glob(f"{category}-*.txt"):
            old.unlink()
        for n, i in enumerate(range(0, len(names), CHUNK), 1):
            path = out / f"{category}-{n}.txt"
            path.write_text("\n".join(names[i:i + CHUNK]) + "\n")
            print(f"{path}\t{len(names[i:i + CHUNK])}")
        print(f"# {category}: {len(names)}")


if __name__ == "__main__":
    main()
