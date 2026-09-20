#!/usr/bin/env python3
"""Render CHANGELOG.md from lua/changelog.lua, the changelog the plugin shows.

lua/changelog.lua is the single source of truth: it is what players read in
Settings, and CHANGELOG.md is generated from it so the two can never disagree.

    tools/changelog.py            write CHANGELOG.md
    tools/changelog.py --check    exit 1 (and print a diff) if it is out of date

Python, not Lua, only because CI and every developer machine already has
python3 and a Lua interpreter is not part of this repository's toolchain
(tools/ci/run.sh already needs python3). The reader below understands the
subset of Lua that lua/changelog.lua's `C.releases` table uses: a list of
tables with `version`, `title`, `blurb` and `items`, each item a
`{ 'tag', 'text' }` pair of single-quoted strings.
"""

import difflib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "lua", "changelog.lua")
TARGET = os.path.join(ROOT, "CHANGELOG.md")

# tag -> (label in the file, heading for a released section)
TAGS = {
    "new": ("NEW", "Added"),
    "fix": ("FIX", "Fixed"),
    "beta": ("BETA", "Merged, not yet verified in game"),
    "next": ("SOON", "Being built"),
}

HEADER = """# Changelog

Every change to Ghostty for FFXIV that a player can see, newest first, in the
words the plugin uses in game.

<!-- Generated from lua/changelog.lua by tools/changelog.py. Do not edit this
     file: edit lua/changelog.lua, the changelog shown in Settings, and run
     tools/changelog.py. CI fails when the two disagree. -->

Statuses mean exactly what they mean in the Changelog tab in game:

* **NEW** / **FIX** — in a release, seen working in game.
* **BETA** — merged, but not yet verified in game.
* **SOON** — still being built.
"""


class LuaError(Exception):
    pass


def read_string(text, i):
    """Read a single- or double-quoted Lua string starting at text[i]."""
    quote = text[i]
    if quote not in "\"'":
        raise LuaError("expected a quoted string at offset %d" % i)
    out = []
    i += 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            nxt = text[i + 1]
            out.append({"n": "\n", "t": "\t", "\\": "\\", "'": "'", '"': '"'}.get(nxt, nxt))
            i += 2
            continue
        if c == quote:
            return "".join(out), i + 1
        if c == "\n":
            raise LuaError("unterminated string at offset %d" % i)
        out.append(c)
        i += 1
    raise LuaError("unterminated string at the end of the file")


def field(chunk, name):
    """The value of `name = '...'` in a release's header text."""
    m = re.search(r"\b%s\s*=\s*['\"]" % name, chunk)
    if not m:
        raise LuaError("no %s in release %r" % (name, chunk[:60]))
    value, _ = read_string(chunk, m.end() - 1)
    return value


def parse(text):
    """The releases of lua/changelog.lua, in file order."""
    start = text.index("C.releases")
    releases = []
    for m in re.finditer(r"\bversion\s*=\s*['\"]", text[start:]):
        head = start + m.start()
        items_at = text.index("items = {", head)
        chunk = text[head:items_at]
        rel = {
            "version": field(chunk, "version"),
            "title": field(chunk, "title"),
            "blurb": field(chunk, "blurb"),
            "items": [],
        }
        i = items_at + len("items = {")
        while True:
            brace = text.find("{", i)
            close = text.find("}", i)
            if brace == -1 or close < brace:  # the items table ended
                break
            j = brace + 1
            while text[j] in " \t\n":
                j += 1
            tag, j = read_string(text, j)
            while text[j] in " \t\n,":
                j += 1
            body, j = read_string(text, j)
            if tag not in TAGS:
                raise LuaError("unknown status %r in %s" % (tag, rel["version"]))
            rel["items"].append((tag, body))
            i = text.index("}", j) + 1
        if not rel["items"]:
            raise LuaError("no items in release %s" % rel["version"])
        releases.append(rel)
    if not releases:
        raise LuaError("no releases found in %s" % SOURCE)
    return releases


def render(releases):
    out = [HEADER]
    for rel in releases:
        unreleased = rel["version"] == "next"
        if unreleased:
            out.append("\n## [Unreleased] — %s\n" % rel["title"])
        else:
            out.append("\n## [%s] — %s\n" % (rel["version"], rel["title"]))
        out.append("\n%s\n" % rel["blurb"])
        groups = []
        for tag, body in rel["items"]:
            if not groups or groups[-1][0] != tag:
                groups.append((tag, []))
            groups[-1][1].append(body)
        single = len({tag for tag, _ in rel["items"]}) == 1
        for tag, bodies in groups:
            if not single:
                out.append("\n### %s\n" % TAGS[tag][1])
            out.append("\n")
            for body in bodies:
                out.append("* %s\n" % body)
    return "".join(out)


def main(argv):
    check = "--check" in argv[1:]
    if [a for a in argv[1:] if a != "--check"]:
        sys.stderr.write(__doc__)
        return 2
    with open(SOURCE, encoding="utf-8") as fh:
        wanted = render(parse(fh.read()))
    if not check:
        with open(TARGET, "w", encoding="utf-8") as fh:
            fh.write(wanted)
        print("wrote %s" % os.path.relpath(TARGET, ROOT))
        return 0
    try:
        with open(TARGET, encoding="utf-8") as fh:
            have = fh.read()
    except FileNotFoundError:
        have = ""
    if have == wanted:
        print("CHANGELOG.md matches lua/changelog.lua")
        return 0
    sys.stdout.writelines(
        difflib.unified_diff(
            have.splitlines(True), wanted.splitlines(True),
            "CHANGELOG.md", "lua/changelog.lua (rendered)",
        )
    )
    sys.stderr.write(
        "\nCHANGELOG.md is out of date: edit lua/changelog.lua and run tools/changelog.py\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
