#!/usr/bin/env python3
"""Install a private candidate or check recorded D17 prerequisites. Never publishes."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import zipfile

import release

CHECKS = (
    "public_source", "history_privacy", "license_and_notices", "plogon_source_build",
    "windowing_api", "gameplay_review", "meaningful_human_review", "ai_disclosure",
)
RUNTIME_CHECKS = (
    "clean_install", "terminal_input_output", "missing_transport", "settings_persist",
    "unload_reload", "game_restart", "read_only_install", "umbra_absent",
)


def snapshot(package: Path) -> tuple[bytes, dict, dict]:
    if package.stat().st_size > release.MAX_TOTAL:
        raise release.ReleaseError("compressed package exceeds size limit")
    data = package.read_bytes()
    manifest, hashes = release.inspect_package(io.BytesIO(data))
    return data, manifest, hashes


def install(package: Path, destination: Path, expected_hash: str | None = None) -> dict:
    # Validate one immutable snapshot, then extract those same bytes, not a
    # second read of a path that could change after validation.
    data, manifest, hashes = snapshot(package)
    digest = hashlib.sha256(data).hexdigest()
    if expected_hash is not None and expected_hash.lower() != digest:
        raise release.ReleaseError("package SHA-256 does not match the supplied value")
    destination = destination.absolute()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.mkdir(mode=0o700, exist_ok=False)
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for member in archive.infolist():
                name = member.filename.replace("\\", "/")
                target = destination.joinpath(*name.split("/"))
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with target.open("xb") as output:
                    output.write(archive.read(member))
                if os.name != "nt":
                    target.chmod(0o600)
        for name, expected in hashes.items():
            if hashlib.sha256((destination / name).read_bytes()).hexdigest() != expected:
                raise release.ReleaseError("installed payload hash mismatch")
    except BaseException:
        shutil.rmtree(destination)
        raise
    return {"dll": str(destination / "GhosttyDalamud.dll"), "package_sha256": digest,
            "version": manifest["AssemblyVersion"], "api": manifest["DalamudApiLevel"]}


def record(package: Path, root: Path) -> dict:
    data, manifest, _ = snapshot(package)
    return {
        "schema": 1,
        "source_commit": release.git(root, "rev-parse", "HEAD"),
        "source_dirty": bool(release.git(root, "status", "--porcelain", "--untracked-files=normal")),
        "package_sha256": hashlib.sha256(data).hexdigest(),
        "assembly_version": manifest["AssemblyVersion"],
        "api": manifest["DalamudApiLevel"],
        "reviewer": "",
        "ai_level": "Auto",
        "ai_notes": "AI implemented this preparation from maintainer direction. Human review is not yet recorded.",
        "checks": {name: {"passed": None, "evidence": ""} for name in CHECKS},
        "runtime": {platform: {"game_version": "", "dalamud_version": "", "tested_at": "",
                    "checks": {name: None for name in RUNTIME_CHECKS}, "notes": ""}
                    for platform in ("windows", "wine")},
    }


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if (len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n"
            or data[8:12] != b"\0\0\0\r" or data[12:16] != b"IHDR"):
        raise release.ReleaseError("icon must be a PNG with an IHDR header")
    width, height = struct.unpack(">II", data[16:24])
    if width != height or not 64 <= width <= 512:
        raise release.ReleaseError("icon must be square, from 64x64 to 512x512")
    # Header validation is not an artistic/provenance review or an image decoder.
    return width, height


def evidence_errors(evidence: dict, commit: str, digest: str, manifest: dict) -> list[str]:
    errors: list[str] = []
    if not isinstance(evidence, dict):
        return ["testing record must be an object"]
    if evidence.get("schema") != 1:
        errors.append("unsupported testing record schema")
    if evidence.get("source_commit") != commit:
        errors.append("testing record refers to a different source commit")
    if evidence.get("package_sha256") != digest:
        errors.append("testing record refers to a different package")
    if evidence.get("source_dirty") is not False:
        errors.append("candidate was recorded from a dirty or unknown source tree")
    if evidence.get("assembly_version") != manifest["AssemblyVersion"] or evidence.get("api") != manifest["DalamudApiLevel"]:
        errors.append("testing record version/API differs from the artifact")
    if not isinstance(evidence.get("reviewer"), str) or not evidence["reviewer"].strip():
        errors.append("meaningful human review needs a named reviewer (a public handle is sufficient)")
    if evidence.get("ai_level") not in ("Assist", "Pair", "Copilot", "Auto"):
        errors.append("disclose the actual non-autocomplete AI involvement")
    if not isinstance(evidence.get("ai_notes"), str) or not evidence["ai_notes"].strip():
        errors.append("AI disclosure details are missing")
    checks = evidence.get("checks", {})
    if not isinstance(checks, dict):
        checks = {}
    for name in CHECKS:
        item = checks.get(name)
        if (not isinstance(item, dict) or item.get("passed") is not True
                or not isinstance(item.get("evidence"), str) or not item["evidence"].strip()):
            errors.append("unverified: " + name)
    runtime = evidence.get("runtime", {})
    if not isinstance(runtime, dict):
        runtime = {}
    for platform in ("windows", "wine"):
        result = runtime.get(platform)
        if not isinstance(result, dict):
            errors.append("missing runtime test: " + platform)
            continue
        for field in ("game_version", "dalamud_version", "tested_at"):
            if not isinstance(result.get(field), str) or not result[field].strip():
                errors.append(f"{platform}: missing {field}")
        tests = result.get("checks", {})
        if not isinstance(tests, dict):
            tests = {}
        for name in RUNTIME_CHECKS:
            if tests.get(name) is not True:
                errors.append(f"{platform}: unverified {name}")
    return errors


def preflight(package: Path, root: Path, evidence: dict, icon: Path) -> list[str]:
    data, manifest, _ = snapshot(package)
    commit = release.git(root, "rev-parse", "HEAD")
    errors = evidence_errors(evidence, commit, hashlib.sha256(data).hexdigest(), manifest)
    if release.git(root, "status", "--porcelain", "--untracked-files=normal"):
        errors.append("source checkout is dirty; commit the reviewed sources and rebuild/retest")
    source_path = "shim/GhosttyDalamud/GhosttyDalamud.json"
    source = json.loads(release.git(root, "show", f"HEAD:{source_path}"))
    release.inspect_package(io.BytesIO(data), source)
    lock = "shim/GhosttyDalamud/packages.lock.json"
    tracked = set(release.git(root, "ls-files").splitlines())
    if lock not in tracked:
        errors.append("commit the lock file generated by a real dotnet restore/build")
    else:
        try:
            contents = json.loads((root / lock).read_text(encoding="utf-8"))
            deps = contents.get("dependencies", {})
            packages = [v.get("DalamudPackager", {}) for v in deps.values() if isinstance(v, dict)]
            if not any(p.get("resolved") == "15.0.0" and p.get("contentHash") for p in packages):
                errors.append("generated lock file does not pin DalamudPackager 15.0.0")
        except (ValueError, AttributeError):
            errors.append("invalid generated lock file")
    if not any(name in tracked for name in ("LICENSE", "LICENSE.md", "LICENSE.txt")):
        errors.append("project license has not been selected and committed")
    try:
        png_size(icon)
        if icon.resolve().relative_to(root.resolve()).as_posix() not in tracked:
            errors.append("commit the reviewed installer icon before rebuilding")
    except (OSError, ValueError) as exc:
        errors.append("installer icon: " + str(exc))
    # Check all locally fetched refs. PR caches and external copies still need
    # the explicit history_privacy review above; this cannot certify erasure.
    identities = release.git(root, "log", "--all", "--format=%an%x00%ae%x00%cn%x00%ce")
    for row in identities.splitlines():
        fields = row.split("\0")
        if len(fields) != 4 or any(fields[i] != "Spaceghost" or not fields[i + 1].endswith("@users.noreply.github.com") for i in (0, 2)):
            errors.append("fetched history still contains non-pseudonymous commit identity metadata")
            break
    return errors


def write_new(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
    if os.name != "nt":
        path.chmod(0o600)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("install", "record", "preflight"))
    parser.add_argument("--package", required=True, type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--sha256")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--icon", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "install":
            if args.destination is None:
                raise release.ReleaseError("install requires a new --destination directory")
            result = install(args.package, args.destination, args.sha256)
            print(json.dumps(result, indent=2))
            if os.name != "nt":
                print("Wine Z: path (verify your prefix maps / to Z:): Z:" + result["dll"].replace("/", "\\"))
            print("Add the DLL to /xlsettings > Experimental > Dev Plugin Locations; enable it in /xlplugins > Dev Tools.")
            print("Configuration, tokens and launcher settings were not modified. No process was launched.")
        elif args.command == "record":
            if args.output is None:
                raise release.ReleaseError("record requires --output; existing test records are never overwritten")
            write_new(args.output, record(args.package, args.root))
            print("Created an unverified test record. Fill it only from actual human review and in-game tests.")
        else:
            if args.evidence is None:
                raise release.ReleaseError("preflight requires --evidence")
            evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
            errors = preflight(args.package, args.root, evidence, args.icon or args.root / "images/icon.png")
            for error in errors:
                print("BLOCKED: " + error)
            if errors:
                return 1
            print("Recorded prerequisites and local checks pass. This is not upstream approval; verify public clone access and submit testing/live only.")
        return 0
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.CalledProcessError) as exc:
        print("candidate: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
