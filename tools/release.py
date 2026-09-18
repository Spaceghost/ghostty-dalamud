#!/usr/bin/env python3
"""Validate a DalamudPackager ZIP and prepare distribution metadata (no uploads)."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import sys
from urllib.parse import urlsplit
import zipfile

NAME = "GhosttyDalamud"
REPOSITORY = "https://github.com/Spaceghost/ghostty-dalamud"
LUA_FILES = {
    "animation.lua", "bell.lua", "changelog.lua", "init.lua", "keymap.lua",
    "migrate.lua", "settings.lua", "showcase.lua", "vote.lua", "world.lua",
}
PAYLOAD = {f"{NAME}.dll", f"{NAME}.json", "ghostty_core.dll"} | {
    f"lua/{name}" for name in LUA_FILES
}
MAX_FILE = 128 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024


class ReleaseError(ValueError):
    """An artifact is unsafe, incomplete, or inconsistent."""


def validate_manifest(manifest: dict) -> dict:
    if not isinstance(manifest, dict):
        raise ReleaseError("manifest must be an object")
    for key in ("Author", "Name", "Description", "Punchline", "RepoUrl"):
        if not isinstance(manifest.get(key), str) or not manifest[key].strip():
            raise ReleaseError(f"missing manifest field: {key}")
    if manifest.get("InternalName") != NAME:
        raise ReleaseError("InternalName must be GhosttyDalamud")
    if manifest["Author"] != "Spaceghost" or manifest["RepoUrl"] != REPOSITORY:
        raise ReleaseError("unexpected public author or source repository")
    version = manifest.get("AssemblyVersion", "")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", version):
        raise ReleaseError("AssemblyVersion must have four numeric components")
    if any(int(part) > 65534 for part in version.split(".")):
        raise ReleaseError("AssemblyVersion component out of range")
    if type(manifest.get("DalamudApiLevel")) is not int or manifest["DalamudApiLevel"] < 1:
        raise ReleaseError("DalamudApiLevel must be a positive integer")
    return manifest


def validate_pe(data: bytes, name: str) -> None:
    # Structural sanity only, not a native/managed API or dependency audit.
    if len(data) < 64 or data[:2] != b"MZ":
        raise ReleaseError(f"{name}: not a PE DLL")
    offset = struct.unpack_from("<I", data, 0x3C)[0]
    if offset < 64 or offset + 26 > len(data) or data[offset:offset + 4] != b"PE\0\0":
        raise ReleaseError(f"{name}: invalid PE header")
    machine = struct.unpack_from("<H", data, offset + 4)[0]
    characteristics = struct.unpack_from("<H", data, offset + 22)[0]
    magic = struct.unpack_from("<H", data, offset + 24)[0]
    if machine != 0x8664 or magic != 0x20B or not characteristics & 0x2000:
        raise ReleaseError(f"{name}: expected an x64 PE32+ DLL")


def inspect_package(path: Path, source_manifest: dict | None = None) -> tuple[dict, dict]:
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        names: dict[str, zipfile.ZipInfo] = {}
        total = 0
        for member in members:
            original = member.filename
            name = original.replace("\\", "/")
            parts = PurePosixPath(name).parts
            if (not parts or name.startswith("/") or ":" in name or ".." in parts
                    or "//" in name or name.startswith("./") or "/./" in name):
                raise ReleaseError(f"unsafe archive path: {original}")
            # DalamudPackager can emit backslashes when built on Windows.
            if member.is_dir() or name.endswith("/"):
                raise ReleaseError(f"unexpected directory entry: {name}")
            if name.lower() in {n.lower() for n in names}:
                raise ReleaseError(f"duplicate archive path: {name}")
            mode = member.external_attr >> 16
            if mode & 0o170000 == 0o120000 or member.flag_bits & 1:
                raise ReleaseError(f"symlink or encrypted archive entry: {name}")
            if name not in PAYLOAD:
                raise ReleaseError(f"unapproved payload file: {name}")
            total += member.file_size
            if member.file_size > MAX_FILE or total > MAX_TOTAL:
                raise ReleaseError("package exceeds size limits")
            names[name] = member
        missing = PAYLOAD - names.keys()
        if missing:
            raise ReleaseError("missing payload files: " + ", ".join(sorted(missing)))
        manifest = validate_manifest(json.loads(archive.read(names[f"{NAME}.json"])))
        if source_manifest is not None:
            source = validate_manifest(source_manifest)
            for key in ("InternalName", "AssemblyVersion", "DalamudApiLevel", "Author", "RepoUrl"):
                if source[key] != manifest[key]:
                    raise ReleaseError(f"built manifest differs from source: {key}")
        hashes = {}
        for name, member in sorted(names.items()):
            data = archive.read(member)  # validates each member's CRC, too
            if name.endswith(".dll"):
                validate_pe(data, name)
            hashes[name] = hashlib.sha256(data).hexdigest()
    return manifest, hashes


def download_url(url: str) -> str:
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment
            or not parsed.path.endswith(".zip")):
        raise ReleaseError("download URL must be HTTPS, end in .zip, and contain no credentials/query/fragment")
    if "/latest/" in parsed.path:
        raise ReleaseError("use an immutable versioned download URL, not /latest/")
    return url


def repository_entry(manifest: dict, url: str, timestamp: int, channel: str) -> list[dict]:
    manifest = validate_manifest(manifest)
    if channel not in {"testing", "stable"} or timestamp <= 0:
        raise ReleaseError("invalid release channel or timestamp")
    url = download_url(url)
    entry = dict(manifest)
    entry.update(LastUpdate=timestamp, IsHide=False, IsTestingExclusive=channel == "testing",
                 DownloadLinkInstall=url, DownloadLinkUpdate=url, DownloadLinkTesting=url)
    if channel == "testing":
        entry.update(TestingAssemblyVersion=manifest["AssemblyVersion"],
                     TestingDalamudApiLevel=manifest["DalamudApiLevel"])
    return [entry]


def submission_manifest(commit: str, changelog: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or commit == "0" * 40:
        raise ReleaseError("submission requires an exact, nonzero 40-character commit SHA")
    if not changelog.strip():
        raise ReleaseError("a changelog is required")
    # JSON basic strings also satisfy TOML basic-string escaping for this text.
    return ("[plugin]\n" + f'repository = "{REPOSITORY}.git"\n'
            + f'commit = "{commit}"\n' + 'owners = ["Spaceghost"]\n'
            + 'project_path = "shim/GhosttyDalamud"\n'
            + f"changelog = {json.dumps(changelog, ensure_ascii=False)}\n")


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "repo", "submission"))
    parser.add_argument("--package", type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--download-url")
    parser.add_argument("--timestamp", type=int, help="release/source commit Unix timestamp")
    parser.add_argument("--channel", choices=("testing", "stable"), default="testing")
    parser.add_argument("--commit", help="exact commit personally tested; required for submission")
    parser.add_argument("--changelog", default="Initial Ghostty testing submission.")
    args = parser.parse_args()
    try:
        if args.command == "submission":
            if not args.commit or not args.output:
                raise ReleaseError("submission needs --commit and --output")
            # Deliberately no implicit HEAD selection: a later commit is not the tested commit.
            resolved = git(args.root, "rev-parse", f"{args.commit}^{{commit}}")
            if resolved != args.commit:
                raise ReleaseError("commit must be a full SHA present in this checkout")
            result = submission_manifest(args.commit, args.changelog)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(result, encoding="utf-8")
            print("Draft manifest only. Complete docs/PUBLISHING.md before upstream submission.")
            return 0
        if not args.package:
            raise ReleaseError("--package is required")
        source = json.loads((args.root / f"shim/{NAME}/{NAME}.json").read_text(encoding="utf-8"))
        manifest, hashes = inspect_package(args.package, source)
        if args.command == "repo":
            if not args.download_url or not args.output or args.timestamp is None:
                raise ReleaseError("repo needs --download-url, --timestamp and --output")
            result = repository_entry(manifest, args.download_url, args.timestamp, args.channel)
        else:
            result = {"manifest": manifest, "files": hashes,
                      "package_sha256": hashlib.sha256(args.package.read_bytes()).hexdigest()}
        text = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(text, encoding="utf-8")
        else:
            print(text, end="")
        return 0
    except (ReleaseError, OSError, zipfile.BadZipFile, json.JSONDecodeError,
            subprocess.CalledProcessError) as exc:
        print(f"release: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
