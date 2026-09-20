#!/usr/bin/env python3
"""Atomically publish identity-only rewrites of all snapshotted branches.

Run only in a disposable full clone. Preserve branch-specific work. Ref changes,
tags, unrelated roots, binary matches and stale leases stop publication.
"""
from __future__ import annotations
import importlib.util
from pathlib import Path
import subprocess
import sys


def git(*args: str) -> bytes:
    return subprocess.check_output(['git', *args])


def parse(data: bytes) -> dict[str, str]:
    refs = {}
    for line in data.splitlines():
        oid, ref = line.decode().split('\t')
        if not ref.startswith('refs/heads/'):
            raise RuntimeError('Unexpected non-branch ref; review tags explicitly.')
        if ref in refs:
            raise RuntimeError('Duplicate ref in snapshot.')
        refs[ref] = oid
    if 'refs/heads/master' not in refs:
        raise RuntimeError('Snapshot has no master branch.')
    return refs


def remote_refs() -> dict[str, str]:
    return parse(git('ls-remote', '--heads', '--tags', 'origin'))


def publish(snapshot: Path) -> str:
    expected = parse(snapshot.read_bytes())
    if remote_refs() != expected:
        raise RuntimeError('Remote refs moved before rewriting; no changes published.')
    if git('status', '--porcelain').strip():
        raise RuntimeError('Working tree is not clean.')
    head = git('rev-parse', 'HEAD').strip().decode()
    if head != expected['refs/heads/master']:
        raise RuntimeError('Checkout does not match the snapshotted master.')
    source = Path('tools/rewrite-identity.py').resolve()
    spec = importlib.util.spec_from_file_location('identity_rewrite', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    original = module.root_identity(head)
    rewritten = {}
    for ref, old in sorted(expected.items()):
        if module.root_identity(old) != original:
            raise RuntimeError('Branches have different original identities; review manually.')
        new, commits, objects = module.rewrite(old, b'Spaceghost', b'251370+Spaceghost@users.noreply.github.com')
        rewritten[ref] = new
        print(f'{ref}: {commits} commits rewritten; {objects} objects checked; 0 original identity remnants.', flush=True)
    if remote_refs() != expected:
        raise RuntimeError('Remote refs moved during rewriting; no changes published.')
    command = ['git', 'push', '--atomic']
    command.extend(f'--force-with-lease={ref}:{old}' for ref, old in sorted(expected.items()))
    command.append('origin')
    command.extend(f'{new}:{ref}' for ref, new in sorted(rewritten.items()))
    subprocess.run(command, check=True)
    if remote_refs() != rewritten:
        raise RuntimeError('Refs changed after publication; inspect the remote before proceeding.')
    new_head = rewritten['refs/heads/master']
    git('update-ref', 'refs/heads/master', new_head, head)
    git('reset', '--hard', new_head)
    print('New master:', new_head)
    print('External clones and GitHub-managed cached objects/workflow metadata were not purged.')
    return new_head


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: rewrite-branches.py EXPECTED_REF_SNAPSHOT')
    publish(Path(sys.argv[1]))
