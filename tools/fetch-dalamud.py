#!/usr/bin/env python3
"""Fetch and verify the pinned Dalamud reference bundle, not a mutable cache."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
import urllib.request
import zipfile


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def cached(target: Path, expected: str) -> bool:
    try:
        data = json.loads((target / '.bundle.json').read_text())
        files = data['files']
        actual = {str(p.relative_to(target)) for p in target.rglob('*') if p.is_file() and p.name != '.bundle.json'}
        return data['git_blob_sha1'] == expected and 'Dalamud.dll' in files and actual == set(files) and all(digest(target / p) == h for p, h in files.items())
    except (OSError, ValueError, KeyError, TypeError):
        return False


def install(url: str, expected: str, target: Path) -> None:
    if not url.startswith('https://raw.githubusercontent.com/goatcorp/dalamud-distrib/'):
        raise ValueError('Expected the official immutable Dalamud distribution URL')
    if cached(target, expected):
        print('Dalamud reference bundle: verified cached files')
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        raise RuntimeError('Reference cache is unverified or modified. Move vendor/dalamud aside, then fetch again.')
    with tempfile.TemporaryDirectory(prefix='.dalamud-fetch-', dir=target.parent) as tmp:
        root = Path(tmp)
        archive = root / 'bundle.zip'
        with urllib.request.urlopen(url, timeout=120) as response, archive.open('wb') as out:
            shutil.copyfileobj(response, out)
        h = hashlib.sha1(f'blob {archive.stat().st_size}\0'.encode())
        with archive.open('rb') as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b''):
                h.update(chunk)
        if h.hexdigest() != expected:
            raise RuntimeError('Reference bundle differs from its pinned Git blob; refusing extraction')
        stage = root / 'stage'
        stage.mkdir()
        with zipfile.ZipFile(archive) as z:
            for entry in z.infolist():
                path = PurePosixPath(entry.filename)
                mode = (entry.external_attr >> 16) & 0xffff
                if path.is_absolute() or '..' in path.parts or '\\' in entry.filename or ':' in entry.filename or stat.S_ISLNK(mode):
                    raise RuntimeError('Unsafe reference archive path')
            z.extractall(stage)
        if not (stage / 'Dalamud.dll').is_file():
            raise RuntimeError('Reference bundle has no root Dalamud.dll')
        files = {str(p.relative_to(stage)): digest(p) for p in stage.rglob('*') if p.is_file()}
        (stage / '.bundle.json').write_text(json.dumps({'git_blob_sha1': expected, 'archive_sha256': digest(archive), 'files': files}, sort_keys=True))
        stage.rename(target)
    print('Dalamud reference bundle: verified and installed')

if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit('usage: fetch-dalamud.py URL GIT_BLOB_SHA1 DIRECTORY')
    install(sys.argv[1], sys.argv[2], Path(sys.argv[3]))
