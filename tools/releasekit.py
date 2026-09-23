#!/usr/bin/env python3
"""Cut, describe and verify a release. The same file in every one of these mods.

Run it through tools/release.sh; the release workflow calls the rest:

  release test [X.Y.Z]      cut the next testing build of X.Y.Z (default: the version
                            in the manifest, or the next patch once that one is stable)
  release stable X.Y.Z      cut the stable release X.Y.Z
  check-tag TAG             (workflow) the tag is well formed, on master, and names the
                            version in the manifest
  title TAG                 (workflow) the release's title
  notes TAG --assets DIR    (workflow) the release notes, from the changelog
  installer-notes TAG       (workflow) the few lines Dalamud's installer shows
  verify TAG                the release, its files, the listing and every download
  changes TAG               what was merged into master for this build, per channel:
                            since the previous test build and since the last stable
                            release (testing), or since the last stable (stable)
  auto-test --sha SHA       (workflow) the testing channel on its own: after CI is green
                            on a master commit, cut the next test build of it. The
                            version commit is made on top of SHA and only the tag is
                            pushed, so master is never written to

Versions. A tag is vX.Y.Z (stable) or vX.Y.Z-test.N (testing). Dalamud compares the
four-part AssemblyVersion, so the fourth number counts builds of X.Y.Z: test N is
X.Y.Z.N, and the stable release is one more than the last test (X.Y.Z.0 when there was
none). Every build is therefore newer than the one before it, and a tester on
X.Y.Z-test.N is offered the stable X.Y.Z.

A test tag made by auto-test points at a `Release <tag>` commit whose parent is the master
commit it builds and which changes nothing but the version files. That is how a build is
cut without writing to master: the tag carries the version, master keeps the one it had,
and the next build counts on from the tags, not from the manifest.

Everything a repository has to say about itself is in tools/release.conf. Python 3.9+
and the standard library only; `release` and `verify` also need git and an
authenticated gh.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LISTING = "https://spacegho.st/mods/ffxiv/plugins.json"
LISTING_PAGE = "https://spacegho.st/mods/ffxiv/plugins/"
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-test\.([1-9]\d*))?$")
# status -> heading in the release notes; "next" is not in the build, so not in the notes
GROUPS = (
    ("new", "New"),
    ("fix", "Fixed"),
    ("beta", "In this build, not yet verified in game"),
)
LISTING_WAIT = 30 * 60  # the listing is cached at the edge and again at its source
CI_WAIT = 45 * 60


class Fail(SystemExit):
    def __init__(self, message: str):
        super().__init__("release: " + message)


def say(message: str) -> None:
    print("== " + message, flush=True)


# ---------------------------------------------------------------- configuration

def conf() -> dict[str, str]:
    """tools/release.conf: KEY=value lines, # comments, no quoting, no expansion."""
    out: dict[str, str] = {}
    for line in (ROOT / "tools" / "release.conf").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    for key in ("NAME", "INTERNAL_NAME", "REPO", "MANIFEST", "VERSION_FILES", "CHANGELOG_TOOL",
                "CHANGELOG_FILES", "BANNER", "SITE", "CI_WORKFLOWS"):
        if key not in out:
            raise Fail(f"tools/release.conf has no {key}")
    return out


def run(*cmd: str, check: bool = True, capture: bool = True) -> str:
    proc = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=capture)
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip() if capture else ""
        raise Fail(f"`{' '.join(cmd)}` failed" + (f":\n{detail}" if detail else ""))
    return (proc.stdout or "").strip() if capture else ""


# ---------------------------------------------------------------- versions

class Version:
    """A release tag, and the AssemblyVersion that goes with it."""

    def __init__(self, tag: str):
        m = TAG_RE.match(tag)
        if not m:
            raise Fail(f"{tag} is not vX.Y.Z or vX.Y.Z-test.N")
        self.tag = tag
        self.base = ".".join(m.group(1, 2, 3))
        self.test = int(m.group(4)) if m.group(4) else None

    @property
    def testing(self) -> bool:
        return self.test is not None

    @property
    def channel(self) -> str:
        return "testing" if self.testing else "stable"


def key(version: str) -> tuple[int, ...]:
    return tuple(int(p) for p in version.split("."))


def manifest_version(c: dict[str, str]) -> str:
    version = json.loads((ROOT / c["MANIFEST"]).read_text(encoding="utf-8"))["AssemblyVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", version):
        raise Fail(f"{c['MANIFEST']}: AssemblyVersion {version!r} is not four numbers")
    return version


def tags() -> list[str]:
    return [t for t in run("git", "tag", "--list", "v*").splitlines() if TAG_RE.match(t)]


def last_test(base: str) -> int:
    return max([Version(t).test or 0 for t in tags() if Version(t).base == base and Version(t).testing],
               default=0)


def stable_bases() -> list[str]:
    return sorted((Version(t).base for t in tags() if not Version(t).testing), key=key)


def bump(c: dict[str, str], old4: str, new4: str, write: bool) -> list[str]:
    """Rewrite the version wherever it lives; returns the files that change."""
    old3, new3 = old4.rsplit(".", 1)[0], new4.rsplit(".", 1)[0]
    plans = [(c["VERSION_FILES"].split(), old4, new4)]
    if old3 != new3:
        plans.append((c.get("BASE_VERSION_FILES", "").split(), old3, new3))
    changed = []
    for files, old, new in plans:
        pattern = re.compile(r"(?<![\d.])" + re.escape(old) + r"(?![\d.])")
        for name in files:
            path = ROOT / name
            lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
            hits = 0
            for i, line in enumerate(lines):
                if "version" in line.lower() and pattern.search(line):
                    lines[i] = pattern.sub(new, line)
                    hits += 1
            if not hits:
                raise Fail(f"{name} does not carry version {old}: the versions in the tree disagree")
            if old != new:
                changed.append(name)
                if write:
                    path.write_text("".join(lines), encoding="utf-8")
    return changed


def plan(c: dict[str, str], kind: str, base: str | None) -> tuple[Version, str]:
    """The tag and the four-part version of the next build of this kind."""
    old4 = manifest_version(c)
    old3 = old4.rsplit(".", 1)[0]
    stables = stable_bases()
    if kind == "test":
        if not base:
            # the newest base a test tag has reached: auto-test builds move past the manifest
            base = max([old3] + [Version(t).base for t in tags() if Version(t).testing], key=key)
            if base in stables:
                x, y, z = key(base)
                base = f"{x}.{y}.{z + 1}"
        build = last_test(base) + 1
        tag = f"v{base}-test.{build}"
    else:
        build = last_test(base) + 1 if last_test(base) else 0
        tag = f"v{base}"
    v = Version(tag)
    if v.base in stables:
        raise Fail(f"{v.base} is already released")
    if stables and key(v.base) <= key(stables[-1]):
        raise Fail(f"{v.base} is not newer than the last stable release, {stables[-1]}")
    if key(v.base) < key(old3):
        raise Fail(f"{v.base} is older than the version in the tree, {old3}")
    new4 = f"{v.base}.{build}"
    if key(new4) <= key(old4) and new4 != old4:
        raise Fail(f"{new4} is not newer than {old4}")
    return v, new4


# ---------------------------------------------------------------- changelog

def changelog(c: dict[str, str]) -> list[dict]:
    """Every section of the changelog: version, title, blurb, date, items[status, text]."""
    return json.loads(run(sys.executable, c["CHANGELOG_TOOL"], "--dump"))


def section(c: dict[str, str], v: Version) -> dict:
    """What a build ships: a testing build the unreleased section, a stable one its own."""
    want = "next" if v.testing else v.base
    for rel in changelog(c):
        if rel["version"] == want:
            return rel
    if v.testing:
        raise Fail("the changelog has no unreleased (next) section: nothing to put in a testing build")
    raise Fail(f"the changelog has no section for {v.base}")


def shipped(rel: dict) -> list[dict]:
    return [i for i in rel["items"] if i["status"] != "next"]


# ---------------------------------------------------------------- what was merged

RELEASE_SUBJECT = re.compile(r"^Release v\d+\.\d+\.\d+(?:-test\.\d+)?$")
PR_REF = re.compile(r"\(#(\d+)\)$|^Merge pull request #(\d+)")


def plain(subject: str) -> str:
    """A commit subject without the (#N) GitHub appends to a squash."""
    return re.sub(r"\s*\(#\d+\)$", "", subject)


def tag_order(t: str) -> tuple:
    """Release order: every test build of X.Y.Z comes before the stable X.Y.Z."""
    v = Version(t)
    return key(v.base) + ((0, v.test) if v.testing else (1, 0))


def previous(v: Version, testing: bool | None) -> str | None:
    """The newest tag released before v: of the given channel, or of either when None."""
    older = [t for t in tags() if tag_order(t) < tag_order(v.tag)
             and (testing is None or Version(t).testing == testing)]
    return max(older, key=tag_order, default=None)


def merged(since: str | None, head: str = "HEAD") -> list[dict]:
    """What landed on master after `since` and up to `head`, oldest first.

    First parent only, so a merged pull request counts once, under its merge or squash
    commit. `Release <tag>` commits are the release machinery, not features, and a tag
    that auto-test put on top of master is reached through its parent all the same."""
    span = f"{since}..{head}" if since else head
    out = []
    for line in run("git", "log", "--first-parent", "--reverse", "--format=%H%x1f%s", span).splitlines():
        sha, _, subject = line.partition("\x1f")
        if not sha or RELEASE_SUBJECT.match(subject):
            continue
        m = PR_REF.search(subject)
        out.append({"sha": sha, "subject": subject, "pr": int(m.group(1) or m.group(2)) if m else None})
    return out


def head_of(v: Version) -> str:
    """Where a build's history ends: its tag once it exists, HEAD while it is being cut."""
    return v.tag if run("git", "rev-parse", "--verify", "--quiet", f"refs/tags/{v.tag}", check=False) else "HEAD"


def changes(c: dict[str, str], v: Version, head: str | None = None) -> str:
    """The merged history of this build, per channel, as Markdown."""
    head = head or head_of(v)
    repo = c["REPO"]

    def listed(items: list[dict]) -> list[str]:
        lines = []
        for i in items:
            ref = f"#{i['pr']}" if i["pr"] else f"[`{i['sha'][:7]}`](https://github.com/{repo}/commit/{i['sha']})"
            lines.append(f"* {md(plain(i['subject']))} ({ref})")
        return lines or ["* Nothing merged."]

    out = []
    stable = previous(v, testing=False)
    if v.testing:
        last = previous(v, testing=None)
        if last and last != stable:
            out.append(f"### Since the previous test build, {last}\n")
            out.extend(listed(merged(last, head)))
            out.append("")
    out.append(f"### Since the last stable release, {stable}\n" if stable else "### Everything so far\n")
    out.extend(listed(merged(stable, head)))
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- notes

def title(c: dict[str, str], v: Version) -> str:
    return f"{c['NAME']} {v.tag}" + (" (testing)" if v.testing else "")


def md(text: str) -> str:
    """Changelog text as Markdown: a bare <word> would otherwise vanish as an HTML tag."""
    parts = text.split("`")
    return "`".join(p if n % 2 else p.replace("<", "&lt;") for n, p in enumerate(parts))


def notes(c: dict[str, str], v: Version, assets: Path | None, rel: dict | None = None) -> str:
    items = shipped(rel or section(c, v))
    repo, name = c["REPO"], c["NAME"]
    unverified = sum(1 for i in items if i["status"] == "beta")
    out = [f'<p align="center"><img src="https://raw.githubusercontent.com/{repo}/{v.tag}/{c["BANNER"]}" '
           f'alt="{name}" width="100%"></p>\n']
    if v.testing:
        out.append(f"> [!WARNING]\n> **Testing build {v.test} of {v.base}.** Only players who turned on testing "
                   f"builds receive it; everyone else stays on the stable release.\n")
    if unverified:
        count = ("Nothing in this build has" if unverified == len(items)
                 else f"{unverified} of the {len(items)} entries in this build have not")
        out.append(f"> [!IMPORTANT]\n> **{count} been verified in game yet.** It is built and tested "
                   f"without the game; entries under *not yet verified in game* say exactly that, and move "
                   f"to *New* once they have been seen working.\n")
    for status, heading in GROUPS:
        texts = [i["text"] for i in items if i["status"] == status]
        if texts:
            out.append(f"## {heading}\n")
            out.extend(f"* {md(t)}" for t in texts)
            out.append("")
    if not items:
        out.append("The changelog has no entries for this build yet; what was merged is below.\n")
    out.append("## Merged\n")
    out.append(changes(c, v))
    out.append("## Install\n")
    out.append(f"1. In game, open `/xlsettings` → **Experimental** → **Custom Plugin Repositories**, add "
               f"`{LISTING}`, press **+**, then **Save and close**.")
    if v.testing:
        out.append("2. Still in **Experimental**, turn on **Get plugin testing builds**.")
        out.append(f"3. Open `/xlplugins`, search for **{name}** and install it. Already installed: right-click "
                   f"it → **Receive plugin testing versions**, then update.")
    else:
        out.append(f"2. Open `/xlplugins`, search for **{name}** and install it. Dalamud updates it from then on.")
    out.append(f"\nStep by step, with pictures: <{LISTING_PAGE}>\n")
    have = {a.name for a in assets.iterdir()} if assets and assets.is_dir() else set()
    agent = c.get("AGENT", "").strip()
    if agent and have & {f"{agent}.fc44.x86_64.rpm", f"{agent}-linux-x86_64.tar.gz"}:
        version = manifest_version(c)
        out.append("\n**The agent.** The plugin talks to `ghostty-agent` on the machine whose shells "
                   "you want. It is the one piece you fetch yourself.\n")
        if f"{agent}.fc44.x86_64.rpm" in have:
            out.append("Fedora 44 or newer, with remote desktop windows:\n")
            out.append("```sh\n"
                       f"sudo dnf install https://github.com/{repo}/releases/download/{v.tag}/{agent}.fc44.x86_64.rpm\n"
                       "systemctl --user enable --now {agent}\n```\n")
        if f"{agent}.fc43.x86_64.rpm" in have:
            out.append("* Fedora 43, and any other rpm distribution with glibc 2.36 or newer: the same with "
                       "`{agent}.fc43.x86_64.rpm` \u2014 terminals, jobs and clips, no compositor.")
        if f"{agent}.apk" in have:
            out.append("* Alpine: `apk add --allow-untrusted {agent}.apk` \u2014 it carries the compositor too.")
        if f"{agent}-linux-x86_64.tar.gz" in have:
            out.append(f"* Any other Linux: `{agent}-{version}-linux-x86_64.tar.gz`, or build a package of "
                       f"your own from `{agent}-{version}-src.tar.gz` with `rpmbuild -tb`.")
        if f"{agent}-{version}-windows-x64.zip" in have:
            out.append(f"* Windows: `{agent}-{version}-windows-x64.zip`.")
        out.append("\nEach carries its own README. The repository's README, under \u201cLinux\u201d, has the rest.\n")

    sums = assets / "SHA256SUMS" if assets else None
    if sums and sums.is_file():
        out.append("## Checksums\n")
        out.append("SHA-256, also attached as `SHA256SUMS` (`sha256sum -c SHA256SUMS`):\n")
        out.append("```\n" + sums.read_text(encoding="utf-8").rstrip() + "\n```\n")
    out.append("## Links\n")
    out.append(f"[{name} on spacegho.st]({c['SITE']}) · "
               f"[Changelog](https://github.com/{repo}/blob/{v.tag}/CHANGELOG.md) · "
               f"[Plugin repository]({LISTING_PAGE}) · "
               f"[Source at this tag](https://github.com/{repo}/tree/{v.tag})")
    return "\n".join(out) + "\n"


def installer_notes(c: dict[str, str], v: Version, limit: int = 2000) -> str:
    """Plain text for the listing's Changelog field, which the installer shows as is."""
    lines = []
    if v.testing:
        lines.append(f"Testing build {v.test} of {v.base}.")
    if any(i["status"] == "beta" for i in shipped(section(c, v))):
        lines.append("BETA: in this build, not yet verified in game.")
    labels = {"new": "NEW", "fix": "FIX", "beta": "BETA"}
    for item in shipped(section(c, v)):
        lead = re.split(r"(?<=[.:;!?])\s", item["text"], maxsplit=1)[0].rstrip(".:;")
        lines.append(f"- {labels[item['status']]}: {lead}")
    if v.testing:
        last = previous(v, testing=None)
        since = merged(last, head_of(v))
        if since:
            lines.append(f"Merged since {last}:" if last else "Merged:")
            lines.extend("- " + plain(i["subject"]) for i in since)
    text = ""
    for n, line in enumerate(lines):
        if len(text) + len(line) > limit:
            text += f"... and {len(lines) - n} more: see CHANGELOG.md.\n"
            break
        text += line + "\n"
    return text.rstrip()


# ---------------------------------------------------------------- check-tag (workflow)

def check_tag(c: dict[str, str], v: Version) -> None:
    have = manifest_version(c)
    base, build = have.rsplit(".", 1)
    if base != v.base:
        raise Fail(f"tag {v.tag} does not name the manifest's version {have}")
    if v.testing and int(build) != v.test:
        raise Fail(f"tag {v.tag} is test {v.test}, the manifest says build {build} ({have})")
    if not v.testing and last_test(v.base) and int(build) <= last_test(v.base):
        raise Fail(f"stable {v.tag} must be newer than its last test build: {have} is not past "
                   f"{v.base}.{last_test(v.base)}")
    bump(c, have, have, write=False)  # every other place the version lives agrees
    master = run("git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/master", check=False)
    if not master:
        raise Fail("origin/master is not here: fetch the full history (fetch-depth: 0)")
    where = "on master"
    if not ancestor("HEAD", master):
        if not (v.testing and version_commit_on(c, v, master)):
            raise Fail(f"{v.tag} is not on master: releases are cut from master only")
        where = "a version commit on master"
    rel = section(c, v)
    since = merged(previous(v, testing=None), "HEAD")
    if not shipped(rel) and not (v.testing and since):
        raise Fail("the changelog section for this build is empty" + (" and nothing was merged" if v.testing else ""))
    say(f"{v.tag}: {c['INTERNAL_NAME']} {have}, {v.channel}, {where}, {len(shipped(rel))} changelog entries, "
        f"{len(since)} merged since the last build")


def ancestor(a: str, b: str) -> bool:
    return subprocess.run(["git", "merge-base", "--is-ancestor", a, b], cwd=ROOT,
                          stderr=subprocess.DEVNULL).returncode == 0


def version_files(c: dict[str, str]) -> set[str]:
    return set(c["VERSION_FILES"].split() + c.get("BASE_VERSION_FILES", "").split())


def version_commit_on(c: dict[str, str], v: Version, master: str) -> bool:
    """HEAD is what auto-test makes: `Release <tag>` on top of a master commit, touching
    nothing but the files that carry the version."""
    parents = run("git", "rev-list", "--parents", "-n", "1", "HEAD").split()[1:]
    if len(parents) != 1 or not ancestor(parents[0], master):
        return False
    if run("git", "log", "-1", "--format=%s", "HEAD") != f"Release {v.tag}":
        return False
    touched = set(run("git", "diff", "--name-only", parents[0], "HEAD").splitlines())
    return bool(touched) and touched <= version_files(c)


# ---------------------------------------------------------------- auto-test (workflow)

BOT = ("github-actions[bot]", "41898282+github-actions[bot]@users.noreply.github.com")


def output(**values: str) -> None:
    """Step outputs for GitHub Actions, and the same lines on stdout."""
    lines = "".join(f"{k}={v}\n" for k, v in values.items())
    print(lines, end="")
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as fh:
            fh.write(lines)


def auto_test(c: dict[str, str], sha: str, push: bool) -> None:
    """Cut the next test build of a master commit whose CI is green, without writing to
    master: the version commit sits on top of it, and only its tag is pushed.

    Nothing is cut when that commit is already in the newest build (a release commit's
    own CI run, or a run that finished after a newer one), or when nothing but release
    commits landed since. Prints tag=<tag> (empty when skipped) and why."""
    if push:
        run("git", "fetch", "--quiet", "--no-tags", "origin", "master", "refs/tags/v*:refs/tags/v*")
    sha = run("git", "rev-parse", "--verify", f"{sha}^{{commit}}")
    master = run("git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/master", check=False)
    if not master or not ancestor(sha, master):
        raise Fail(f"{sha[:7]} is not on origin/master")
    if run("git", "rev-parse", "HEAD") != sha:
        raise Fail(f"check out {sha[:7]} first (detached is fine)")
    if run("git", "status", "--porcelain", "--untracked-files=no"):
        raise Fail("the working tree is not clean")
    newest = max(tags(), key=tag_order, default=None)
    if newest and ancestor(sha, newest):
        say(f"{sha[:7]} is already in {newest}: nothing to cut")
        output(tag="", reason=f"already in {newest}")
        return
    since = merged(newest, sha)
    if not since:
        say(f"nothing but release commits since {newest}: nothing to cut")
        output(tag="", reason=f"nothing merged since {newest}")
        return
    old4 = manifest_version(c)
    v, new4 = plan(c, "test", None)
    say(f"{c['NAME']}: {v.tag} ({new4}) from {sha[:7]}, {len(since)} merged since {newest or 'the start'}")
    bump(c, old4, new4, write=True)
    ident = ["-c", f"user.name={BOT[0]}", "-c", f"user.email={BOT[1]}"]
    files = sorted(version_files(c))
    run("git", "add", "--", *files)
    run("git", *ident, "commit", "--quiet", "-m", f"Release {v.tag}", "-m",
        f"The testing channel's build of {sha}, cut by `tools/releasekit.py auto-test` after CI "
        f"passed on it. Only the version changes; master is not written to.")
    run("git", *ident, "tag", "-a", v.tag, "-m", title(c, v))
    check_tag(c, v)
    if push:
        run("git", "push", "origin", f"refs/tags/{v.tag}")
        say(f"pushed {v.tag}")
    output(tag=v.tag, reason=f"{len(since)} merged since {newest or 'the start'}")


# ---------------------------------------------------------------- verify

def fetch(url: str, tries: int = 4) -> bytes:
    last: Exception | None = None
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "releasekit", "Cache-Control": "no-cache"})
            with urllib.request.urlopen(req, timeout=60) as res:
                return res.read()
        except (urllib.error.URLError, TimeoutError) as err:
            last = err
            time.sleep(3 * (attempt + 1))
    raise Fail(f"{url}: {last}")


def verify(c: dict[str, str], v: Version, version4: str | None, wait: bool = True) -> None:
    repo, internal = c["REPO"], c["INTERNAL_NAME"]
    say(f"verifying {v.tag}")
    info = json.loads(run("gh", "release", "view", v.tag, "--repo", repo, "--json",
                          "assets,isDraft,isPrerelease,name"))
    if info["isDraft"] or info["isPrerelease"] != v.testing:
        raise Fail(f"release {v.tag} is a draft, or on the wrong channel")
    listing_name = "pluginmaster-testing.json" if v.testing else "pluginmaster.json"
    base_url = f"https://github.com/{repo}/releases/download/{v.tag}/"
    entry = json.loads(fetch(base_url + listing_name))[0]
    version4 = version4 or entry["AssemblyVersion"]
    have = {a["name"] for a in info["assets"]}
    want = {"latest.zip", f"{internal}-{version4}.zip", listing_name, "SHA256SUMS"}
    # A mod that ships a host-side helper names it in release.conf as AGENT;
    # the rest of these tools are shared with the other plugins here, and a
    # mod without one must not be asked for artifacts it never builds.
    agent = c.get("AGENT", "").strip()
    if agent:
        want |= {f"{agent}-{version4}-windows-x64.zip",
                 f"{agent}-{version4}-src.tar.gz", f"{agent}-src.tar.gz",
                 f"{agent}-{version4}-linux-x86_64.tar.gz", f"{agent}-linux-x86_64.tar.gz",
                 f"{agent}-{version4}-1.fc44.x86_64.rpm", f"{agent}.fc44.x86_64.rpm",
                 f"{agent}-{version4}-1.fc43.x86_64.rpm", f"{agent}.fc43.x86_64.rpm",
                 f"{agent}-{version4}-r0.apk", f"{agent}.apk"}
    if want - have:
        raise Fail(f"release {v.tag} is missing " + ", ".join(sorted(want - have)))
    print(f"   release   {info['name']}: " + ", ".join(sorted(have)))
    if entry["InternalName"] != internal or entry["AssemblyVersion"] != version4:
        raise Fail(f"{listing_name} says {entry.get('InternalName')} {entry.get('AssemblyVersion')}, "
                   f"expected {internal} {version4}")
    sums = {}
    for line in fetch(base_url + "SHA256SUMS").decode().splitlines():
        digest, _, name = line.partition("  ")
        sums[name.strip()] = digest
    channel_url = (f"https://github.com/{repo}/releases/download/testing/" if v.testing
                   else f"https://github.com/{repo}/releases/latest/download/")
    for where in (base_url, channel_url):
        digest = hashlib.sha256(fetch(where + "latest.zip")).hexdigest()
        if digest != sums.get("latest.zip"):
            raise Fail(f"{where}latest.zip is not the zip this release built (sha256 {digest})")
        print(f"   download  {where}latest.zip  200, sha256 matches")
    field = "TestingAssemblyVersion" if v.testing else "AssemblyVersion"
    deadline = time.time() + (LISTING_WAIT if wait else 0)
    while True:
        live = next((e for e in json.loads(fetch(LISTING)) if e.get("InternalName") == internal), None)
        if live and live.get(field) == version4:
            break
        if time.time() >= deadline:
            seen = live.get(field) if live else "no entry"
            raise Fail(f"{LISTING} still shows {seen} for {internal}, not {version4} (it is cached for "
                       f"some minutes; run `tools/release.sh verify {v.tag}` again)")
        print(f"   listing   shows {live.get(field) if live else 'no entry'}, waiting for {version4} ...", flush=True)
        time.sleep(60)
    if not v.testing and live.get("IsTestingExclusive"):
        raise Fail(f"{LISTING} still marks {internal} as testing only")
    print(f"   listing   {internal} {field} {version4}, author {live.get('Author')}")
    for link in ("DownloadLinkInstall", "DownloadLinkUpdate", "DownloadLinkTesting", "IconUrl"):
        if live.get(link):
            fetch(live[link])
            print(f"   {link}  200")
    say(f"{v.tag} is out: https://github.com/{repo}/releases/tag/{v.tag}")


# ---------------------------------------------------------------- release

def ci_green(c: dict[str, str], sha: str) -> None:
    """Every workflow in CI_WORKFLOWS succeeded for this commit; waits while one runs.

    A commit that only touched paths a workflow ignores (docs) has no run of it: then the
    workflow's newest run on master has to be green instead, and the output says so."""
    wanted = [w.strip() for w in c["CI_WORKFLOWS"].split(",") if w.strip()]
    started, deadline = time.time(), time.time() + CI_WAIT
    while True:
        runs = json.loads(run("gh", "run", "list", "--repo", c["REPO"], "--commit", sha, "--limit", "50",
                              "--json", "workflowName,status,conclusion,headBranch"))
        state = {}
        for r in runs:  # newest first: keep the newest run of each workflow on master
            if r["headBranch"] == "master":
                state.setdefault(r["workflowName"], r)
        if time.time() - started > 90:  # long enough for a run to have been queued
            for w in wanted:
                if w not in state:
                    last = json.loads(run("gh", "run", "list", "--repo", c["REPO"], "--workflow", w, "--branch",
                                          "master", "--limit", "1", "--json", "status,conclusion,headSha"))
                    if not last:
                        raise Fail(f"{w} has never run on master")
                    state[w] = last[0]
                    print(f"   {w} did not run for {sha[:7]} (it ignores what that commit touched); "
                          f"using its newest run on master, for {last[0]['headSha'][:7]}")
        bad = [w for w in wanted if w in state and state[w]["status"] == "completed"
               and state[w]["conclusion"] != "success"]
        if bad:
            raise Fail(f"{', '.join(bad)} failed on master at {sha[:7]}: fix master first")
        pending = [w for w in wanted if w not in state or state[w]["status"] != "completed"]
        if not pending:
            say(f"{', '.join(wanted)} green for {sha[:7]}")
            return
        if time.time() >= deadline:
            raise Fail(f"{', '.join(pending)} did not finish for {sha[:7]}")
        print(f"   waiting for {', '.join(pending)} on {sha[:7]} ...", flush=True)
        time.sleep(30)


def release(c: dict[str, str], kind: str, base: str | None, headline: str | None, dry: bool) -> None:
    repo = c["REPO"]
    run("gh", "auth", "status")
    if run("git", "rev-parse", "--abbrev-ref", "HEAD") != "master":
        raise Fail("not on master")
    if run("git", "status", "--porcelain"):
        raise Fail("the working tree is not clean")
    # release tags only: the floating `testing` tag moves, and a plain --tags trips on it
    run("git", "fetch", "--quiet", "--no-tags", "origin", "master", "refs/tags/v*:refs/tags/v*")
    head = run("git", "rev-parse", "HEAD")
    if head != run("git", "rev-parse", "origin/master"):
        raise Fail("master and origin/master differ: pull or push first")

    old4 = manifest_version(c)
    v, new4 = plan(c, kind, base)
    tag = v.tag
    say(f"{c['NAME']}: {old4} -> {new4}, tag {tag} ({v.channel})" + ("  [dry run]" if dry else ""))

    ci_green(c, head)

    today = datetime.date.today().isoformat()
    sections = {r["version"]: r for r in changelog(c)}
    stamp = not v.testing and v.base not in sections
    source = sections.get("next" if (v.testing or stamp) else v.base)
    if not source or not shipped(source):
        raise Fail("the changelog has nothing for this release: add entries to its unreleased section")
    changed = bump(c, old4, new4, write=not dry)
    if stamp:
        say(f"changelog: unreleased -> {v.base}, {today}")
        if not dry:
            cmd = [sys.executable, c["CHANGELOG_TOOL"], "--release", v.base, "--date", today]
            run(*cmd, *(["--title", headline] if headline else []))
            run(sys.executable, c["CHANGELOG_TOOL"])
    if dry:
        print("   would change: " + ", ".join(changed + (c["CHANGELOG_FILES"].split() if stamp else [])))
        print(f"   would commit, tag {tag}, push master and the tag, then wait for the Release workflow")
        print("-" * 72)
        print(f"# {title(c, v)}\n")
        print(notes(c, v, None, source))
        return
    if c.get("CHECK"):
        run(*c["CHECK"].split())
    run(sys.executable, c["CHANGELOG_TOOL"], "--check")
    files = sorted(set(changed + (c["CHANGELOG_FILES"].split() if stamp else [])))
    if files:
        run("git", "add", "--", *files)
        run("git", "commit", "--quiet", "-m", f"Release {tag}")
    run("git", "tag", "-a", tag, "-m", title(c, v))
    try:
        run("git", "push", "--atomic", "origin", "master", tag)
    except SystemExit:
        print(f"release: the push failed. Nothing is published. To undo locally:\n"
              f"  git tag -d {tag}" + ("\n  git reset --hard origin/master" if files else ""), file=sys.stderr)
        raise
    say(f"pushed {tag}; waiting for the Release workflow")
    sha = run("git", "rev-parse", "HEAD")
    run_id = None
    for _ in range(40):
        found = json.loads(run("gh", "run", "list", "--repo", repo, "--workflow", "Release", "--commit", sha,
                               "--limit", "5", "--json", "databaseId,headBranch"))
        run_id = next((str(r["databaseId"]) for r in found if r["headBranch"] == tag), None)
        if run_id:
            break
        time.sleep(5)
    if not run_id:
        raise Fail(f"no Release run appeared for {tag}: see https://github.com/{repo}/actions")
    print(f"   https://github.com/{repo}/actions/runs/{run_id}")
    if subprocess.run(["gh", "run", "watch", run_id, "--repo", repo, "--exit-status", "--interval", "20"],
                      cwd=ROOT, stdout=subprocess.DEVNULL).returncode != 0:
        raise Fail(f"the Release workflow failed: gh run view {run_id} --repo {repo} --log-failed\n"
                   f"Fix it on master, then re-run that workflow; the tag stays where it is.")
    verify(c, v, new4)


# ---------------------------------------------------------------- command line

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="tools/release.sh", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("test", help="cut the next testing build")
    p.add_argument("version", nargs="?", help="X.Y.Z this build leads up to")
    p.add_argument("--dry-run", "-n", action="store_true")
    p = sub.add_parser("stable", help="cut a stable release")
    p.add_argument("version", help="X.Y.Z")
    p.add_argument("--title", help="the release's name in the changelog (default: Released <date>)")
    p.add_argument("--dry-run", "-n", action="store_true")
    for name in ("check-tag", "title", "installer-notes"):
        sub.add_parser(name).add_argument("tag")
    p = sub.add_parser("notes")
    p.add_argument("tag")
    p.add_argument("--assets", type=Path, help="the folder holding SHA256SUMS")
    sub.add_parser("changes", help="what was merged for a build, per channel").add_argument("tag")
    p = sub.add_parser("auto-test", help="(workflow) cut the next test build of a green master commit")
    p.add_argument("--sha", required=True, help="the master commit CI passed on")
    p.add_argument("--push", action="store_true", help="push the tag (otherwise it stays local)")
    p = sub.add_parser("verify", help="check a published release end to end")
    p.add_argument("tag")
    p.add_argument("--no-wait", action="store_true", help="do not wait for the listing's cache")
    args = ap.parse_args(argv)
    c = conf()
    if args.cmd == "auto-test":
        auto_test(c, args.sha, args.push)
        return 0
    if args.cmd in ("test", "stable"):
        if args.version and not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
            raise Fail(f"{args.version} is not X.Y.Z")
        release(c, args.cmd, args.version, getattr(args, "title", None), args.dry_run)
        return 0
    v = Version(args.tag)
    if args.cmd == "check-tag":
        check_tag(c, v)
    elif args.cmd == "title":
        print(title(c, v))
    elif args.cmd == "notes":
        sys.stdout.write(notes(c, v, args.assets))
    elif args.cmd == "changes":
        sys.stdout.write(changes(c, v))
    elif args.cmd == "installer-notes":
        print(installer_notes(c, v))
    elif args.cmd == "verify":
        verify(c, v, None, wait=not args.no_wait)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
