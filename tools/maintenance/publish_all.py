#!/usr/bin/env python3
"""Publish an identity-only rewrite of all snapshotted branches atomically.

Run from a disposable full clone after committing reviewed repairs to main.
Concurrent changes, unexpected refs, roots, or tags cause a closed failure.
"""
from __future__ import annotations
import importlib.util
import os
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
    if 'refs/heads/main' not in refs:
        raise RuntimeError('Snapshot has no main branch.')
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
    if subprocess.run(['git', 'merge-base', '--is-ancestor', expected['refs/heads/main'], head]).returncode:
        raise RuntimeError('Reviewed main is not based on the snapshotted main.')
    source = Path('tools/rewrite-identity.py').resolve()
    spec = importlib.util.spec_from_file_location('identity_rewrite', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    original = module.root_identity(head)
    rewritten = {}
    for ref, old in sorted(expected.items()):
        tip = head if ref == 'refs/heads/main' else old
        if module.root_identity(tip) != original:
            raise RuntimeError('Branches have different original identities; review manually.')
        new, commits, objects = module.rewrite(tip, b'Spaceghost', b'251370+Spaceghost@users.noreply.github.com')
        rewritten[ref] = new
        print(f'{ref}: {commits} commits rewritten, {objects} objects verified; 0 identity remnants.', flush=True)
    if remote_refs() != expected:
        raise RuntimeError('Remote refs moved during rewriting; no changes published.')
    command = ['git', 'push', '--atomic']
    command.extend(f'--force-with-lease={ref}:{old}' for ref, old in sorted(expected.items()))
    command.append('origin')
    command.extend(f'{new}:{ref}' for ref, new in sorted(rewritten.items()))
    subprocess.run(command, check=True)
    if remote_refs() != rewritten:
        raise RuntimeError('Refs changed after publication; inspect the remote before proceeding.')
    new_head = rewritten['refs/heads/main']
    git('update-ref', 'refs/heads/main', new_head, head)
    git('reset', '--hard', new_head)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
            out.write(f'head={new_head}\n')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as out:
            out.write(f'## Maintenance result\n\nPublished repaired main `{new_head}`.\n\nRewrote {len(rewritten)} branches with atomic leases, preserving their distinct work.\n\nGitHub-managed pull-request refs, cached old objects, workflow metadata and external clones are not purged by this operation.\n')
    return new_head


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: publish_all.py EXPECTED_REF_SNAPSHOT')
    print('New main:', publish(Path(sys.argv[1])))
