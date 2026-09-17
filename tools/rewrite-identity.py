#!/usr/bin/env python3
"""Rewrite the original maintainer identity in a disposable, single-branch clone.

Original identities are read from Git, never stored in tracked configuration or
printed. This command never pushes; publishing requires an explicit leased push.
"""
from __future__ import annotations
import argparse
import re
import subprocess
import sys


def git(*args: str, data: bytes | None = None) -> bytes:
    return subprocess.check_output(['git', *args], input=data)


def root_identity(head: str) -> tuple[bytes, bytes]:
    roots = git('rev-list', '--max-parents=0', head).splitlines()
    if len(roots) != 1:
        raise RuntimeError('Expected one root; review multiple authors/roots manually.')
    raw = git('cat-file', 'commit', roots[0].decode())
    m = re.search(rb'^author (.+) <([^<>]+)> \d+ [+-]\d{4}$', raw, re.M)
    if not m:
        raise RuntimeError('Cannot identify the original maintainer.')
    return m.group(1), m.group(2)


def rewrite(head: str, name: bytes, email: bytes) -> tuple[str, int, int]:
    old_name, old_email = root_identity(head)
    replacements = []
    for old, new in [(old_name, name), (old_email, email)]:
        if old == new:
            continue
        if len(old) < 5:
            raise RuntimeError('Identity is too short for safe literal replacement.')
        for encoding in ('utf-8', 'utf-16le', 'utf-16be'):
            replacements.append((old.decode('utf-8').encode(encoding),
                                 new.decode('utf-8').encode(encoding)))

    def clean(data: bytes) -> bytes:
        for old, new in replacements:
            data = data.replace(old, new)
        return data

    for row in git('log', '--format=%an%x00%ae%x00%cn%x00%ce', head).splitlines():
        fields = row.split(b'\0')
        for n, e in zip(fields[::2], fields[1::2]):
            if e == old_email and n not in (old_name, name):
                raise RuntimeError('Maintainer has an additional name; review before rewriting.')
    size = 32 if git('rev-parse', '--show-object-format').strip() == b'sha256' else 20
    memo: dict[str, str] = {}
    rewritten_commits = 0
    sys.setrecursionlimit(max(10000, int(git('rev-list', '--count', head)) * 4))

    def visit(oid: str) -> str:
        nonlocal rewritten_commits
        if oid in memo:
            return memo[oid]
        kind = git('cat-file', '-t', oid).strip().decode()
        raw = git('cat-file', kind, oid)
        if kind == 'blob':
            out = clean(raw)
        elif kind == 'tree':
            entries = []
            pos = 0
            while pos < len(raw):
                end = raw.index(b'\0', pos)
                mode, filename = raw[pos:end].split(b' ', 1)
                child = raw[end + 1:end + 1 + size].hex()
                new_child = child if mode == b'160000' else visit(child)
                new_name = clean(filename)
                if b'/' in new_name or b'\0' in new_name:
                    raise RuntimeError('Unsafe replacement in a path component.')
                entries.append((mode, new_name, new_child))
                pos = end + 1 + size
            entries.sort(key=lambda e: e[1] + (b'/' if e[0] == b'40000' else b''))
            out = b''.join(m + b' ' + n + b'\0' + bytes.fromhex(c) for m, n, c in entries)
        elif kind == 'commit':
            header, message = raw.split(b'\n\n', 1)
            blocks: list[bytes] = []
            for line in header.splitlines():
                if line.startswith(b' ') and blocks:
                    blocks[-1] += b'\n' + line
                else:
                    blocks.append(line)
            modified = []
            for block in blocks:
                key, _, value = block.partition(b' ')
                if key in (b'tree', b'parent'):
                    block = key + b' ' + visit(value.decode()).encode()
                modified.append(clean(block))
            out = b'\n'.join(modified) + b'\n\n' + clean(message)
            if out != raw:
                modified = [b for b in modified if b.split(b' ', 1)[0]
                            not in (b'gpgsig', b'gpgsig-sha256', b'mergetag')]
                out = b'\n'.join(modified) + b'\n\n' + clean(message)
                rewritten_commits += 1
        else:
            raise RuntimeError('Unsupported reachable object type: ' + kind)
        new = oid if out == raw else git('hash-object', '-w', '-t', kind, '--stdin', data=out).strip().decode()
        memo[oid] = new
        return new

    new_head = visit(head)
    verified = 0
    for line in git('rev-list', '--objects', new_head).splitlines():
        oid = line.split(b' ', 1)[0].decode()
        kind = git('cat-file', '-t', oid).strip().decode()
        data = git('cat-file', kind, oid)
        if any(old in data for old, _ in replacements):
            raise RuntimeError('Identity remnants remain; no ref was changed.')
        verified += 1
    if git('rev-list', '--count', head) != git('rev-list', '--count', new_head):
        raise RuntimeError('Commit count changed; refusing the rewrite.')
    return new_head, rewritten_commits, verified


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--name', required=True)
    ap.add_argument('--email', required=True)
    ap.add_argument('--apply', action='store_true')
    args = ap.parse_args()
    if any(c in args.name + args.email for c in '\r\n<>\0'):
        ap.error('Invalid identity')
    head = git('rev-parse', 'HEAD').strip().decode()
    if not args.apply:
        print('Dry run: --apply is required to rewrite objects and main.')
        return
    refs = git('for-each-ref', '--format=%(refname)', 'refs/heads', 'refs/tags').splitlines()
    if refs != [b'refs/heads/main']:
        raise RuntimeError('This maintenance command requires main to be the only branch/tag.')
    if git('status', '--porcelain').strip():
        raise RuntimeError('Worktree is not clean.')
    new_head, commits, objects = rewrite(head, args.name.encode(), args.email.encode())
    git('update-ref', 'refs/heads/main', new_head, head)
    git('reset', '--hard', new_head)
    print(f'Identity rewrite: {commits} commits rewritten; {objects} reachable objects checked; 0 identity remnants.')
    print('New head:', new_head)


if __name__ == '__main__':
    main()
