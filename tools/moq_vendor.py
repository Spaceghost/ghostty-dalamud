#!/usr/bin/env python3
"""The manifest and lock work behind tools/moq-vendor.sh, kept here so it can be tested.

  moq_vendor.py closure            < cargo-metadata.json   workspace crates moq-iroh-c reaches by path
  moq_vendor.py patched  Cargo.toml                         paths named in [patch.crates-io]
  moq_vendor.py members  Cargo.toml CRATE...                rewrite members, drop default-members
  moq_vendor.py lock-subset FORK.lock CUT.lock              fail if the cut lock moved a version
  moq_vendor.py stub VENDOR KEEP                            stub every crate KEEP does not name
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tomllib


def closure(meta: dict, start: str = 'moq-iroh-c') -> list[str]:
    """Workspace-relative dirs of START and every workspace crate it reaches by path,
    in any dependency kind: cargo loads a member's dev-dependencies to resolve."""
    root = meta['workspace_root']
    by_dir = {os.path.dirname(p['manifest_path']): p for p in meta['packages']}
    by_name = {p['name']: p for p in meta['packages']}
    if start not in by_name:
        raise SystemExit(f'moq-vendor: error: no {start} in the workspace')
    todo, seen = [by_name[start]], set()
    while todo:
        p = todo.pop()
        d = os.path.dirname(p['manifest_path'])
        if d in seen:
            continue
        seen.add(d)
        for dep in p['dependencies']:
            if dep.get('path') and dep['path'] in by_dir:
                todo.append(by_dir[dep['path']])
    return sorted(os.path.relpath(d, root) for d in seen)


def patched(manifest: dict) -> list[str]:
    out = []
    for spec in manifest.get('patch', {}).get('crates-io', {}).values():
        if isinstance(spec, dict) and 'path' in spec:
            out.append(spec['path'])
    return out


def _block(name: str) -> re.Pattern:
    return re.compile(r'^' + name + r'\s*=\s*\[.*?^\]\s*\n', re.S | re.M)


def rewrite_members(text: str, members: list[str]) -> str:
    """The members list becomes MEMBERS; default-members goes (it names crates that
    are not there). Everything else in the manifest stays as it is."""
    new = 'members = [\n' + ''.join(f'    "{m}",\n' for m in members) + ']\n'
    text, n = _block('members').subn(new, text, count=1)
    if n != 1:
        raise SystemExit('moq-vendor: error: no members list in the workspace manifest')
    return _block('default-members').sub('', text, count=1)


def lock_packages(text: str) -> set[tuple]:
    return {(x['name'], x['version'], x.get('source'), x.get('checksum'))
            for x in tomllib.loads(text).get('package', [])}


def lock_moved(fork: str, cut: str) -> list[tuple]:
    """Packages in the cut lock that are not, exactly, in the fork's lock."""
    return sorted(lock_packages(cut) - lock_packages(fork))


def stub_crates(vendor: str, keep: set[tuple[str, str]]) -> tuple[int, int]:
    """Every vendored crate whose (name, version) KEEP does not name becomes a stub:
    its manifest stays (cargo resolves the lock against it), each target path it
    declares becomes an empty file, and .cargo-checksum.json keeps the package's
    sha256 but lists no files, so cargo verifies nothing that is gone."""
    kept = stubbed = 0
    for d in sorted(os.listdir(vendor)):
        root = os.path.join(vendor, d)
        if not os.path.isfile(os.path.join(root, 'Cargo.toml')):
            continue
        with open(os.path.join(root, 'Cargo.toml'), 'rb') as f:
            man = tomllib.load(f)
        pkg = man['package']
        if (pkg['name'], pkg['version']) in keep:
            kept += 1
            continue
        with open(os.path.join(root, '.cargo-checksum.json')) as f:
            sums = json.load(f)
        for e in os.listdir(root):
            if e in ('Cargo.toml', '.cargo-checksum.json'):
                continue
            p = os.path.join(root, e)
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p)
            else:
                os.remove(p)
        paths = {man.get('lib', {}).get('path', 'src/lib.rs')}
        if isinstance(pkg.get('build'), str):
            paths.add(pkg['build'])
        for kind in ('bin', 'example', 'test', 'bench'):
            paths.update(t['path'] for t in man.get(kind, []) if 'path' in t)
        for rel in paths:
            f = os.path.normpath(os.path.join(root, rel))
            if not f.startswith(root + os.sep):
                raise SystemExit(f'moq-vendor: error: {d} names a target outside itself: {rel}')
            os.makedirs(os.path.dirname(f), exist_ok=True)
            open(f, 'w').close()
        with open(os.path.join(root, '.cargo-checksum.json'), 'w') as f:
            json.dump({'files': {}, 'package': sums.get('package')}, f, sort_keys=True)
        stubbed += 1
    return kept, stubbed


def parse_keep(lines) -> set[tuple[str, str]]:
    """`cargo tree --prefix none --format '{p}'` lines: "name v1.2.3 [(...)]"."""
    keep = set()
    for line in lines:
        parts = line.split()
        if len(parts) >= 2 and parts[1].startswith('v'):
            keep.add((parts[0], parts[1][1:]))
    return keep


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == 'closure':
        print('\n'.join(closure(json.load(sys.stdin))))
    elif cmd == 'patched':
        with open(args[0], 'rb') as f:
            print('\n'.join(patched(tomllib.load(f))))
    elif cmd == 'members':
        with open(args[0]) as f:
            text = f.read()
        with open(args[0], 'w') as f:
            f.write(rewrite_members(text, args[1:]))
    elif cmd == 'lock-subset':
        with open(args[0]) as a, open(args[1]) as b:
            fork, cut = a.read(), b.read()
        moved = lock_moved(fork, cut)
        if moved:
            raise SystemExit("moq-vendor: error: resolving moved these off the fork's lock: "
                             + ', '.join(f'{n} {v}' for n, v, _, _ in moved))
        print(f"== moq-vendor: {len(lock_packages(cut))} of the fork's {len(lock_packages(fork))} "
              'locked packages, none moved')
    elif cmd == 'stub':
        with open(args[1]) as f:
            keep = parse_keep(f)
        kept, stubbed = stub_crates(args[0], keep)
        print(f'== moq-vendor: {kept} crates kept whole, {stubbed} that no build here compiles left as stubs')
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
