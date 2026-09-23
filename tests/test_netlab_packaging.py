"""Netlab's Rust library ships offline and pinned: the vendoring logic
(tools/moq_vendor.py), the toolchain pins and their checks
(tools/rust-toolchain.sh), and the agent's packaging (the source tarball's file
list, the spec) agree with one another. No network, no cargo: fake toolchains
and synthetic manifests."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mv = load('moq_vendor', ROOT / 'tools' / 'moq_vendor.py')


def toolchain():
    env = {}
    text = (ROOT / 'toolchain.env').read_text()
    for m in re.finditer(r'^([A-Z0-9_]+)=(?:"((?:[^"\\]|\\.)*)"|(\S*))', text, re.M):
        env[m.group(1)] = m.group(2) if m.group(2) is not None else m.group(3)
    return env


def meta(root, pkgs):
    """cargo metadata --no-deps for PKGS: {name: [(dep, path-or-None, kind)]}."""
    out = []
    for name, deps in pkgs.items():
        out.append({
            'name': name,
            'manifest_path': f'{root}/rs/{name}/Cargo.toml',
            'dependencies': [{'name': d, 'path': (f'{root}/rs/{p}' if p else None), 'kind': k} for d, p, k in deps],
        })
    return {'workspace_root': root, 'packages': out}


class Closure(unittest.TestCase):
    def test_follows_path_deps_of_every_kind_and_nothing_else(self):
        m = meta('/w', {
            'moq-iroh-c': [('moq-tokio', 'moq-tokio', None), ('tokio', None, None)],
            'moq-tokio': [('moq-net', 'moq-net', None), ('moq-sock', 'moq-sock', 'dev')],
            'moq-net': [('kio', 'kio', 'build')],
            'moq-sock': [],
            'kio': [],
            'moq-relay': [('moq-net', 'moq-net', None)],   # not reached from moq-iroh-c
        })
        self.assertEqual(mv.closure(m), ['rs/kio', 'rs/moq-iroh-c', 'rs/moq-net', 'rs/moq-sock', 'rs/moq-tokio'])

    def test_missing_start_is_an_error(self):
        with self.assertRaises(SystemExit):
            mv.closure(meta('/w', {'moq-net': []}))

    def test_patched_paths(self):
        self.assertEqual(mv.patched({'patch': {'crates-io': {'kio': {'path': 'rs/kio'}, 'x': '1.0'}}}), ['rs/kio'])
        self.assertEqual(mv.patched({}), [])


class Members(unittest.TestCase):
    MANIFEST = '''[workspace]
members = [
    "rs/a",
    "rs/moq-iroh-c",
    "rs/b",
]
default-members = [
    "rs/a",
    # "rs/c",
]
resolver = "3"

[workspace.package]
rust-version = "1.91"

[patch.crates-io]
kio = { path = "rs/kio" }
'''

    def test_rewrites_members_drops_default_members_keeps_the_rest(self):
        out = mv.rewrite_members(self.MANIFEST, ['rs/kio', 'rs/moq-iroh-c'])
        self.assertIn('members = [\n    "rs/kio",\n    "rs/moq-iroh-c",\n]\n', out)
        self.assertNotIn('default-members', out)
        self.assertNotIn('rs/a', out)
        for kept in ('resolver = "3"', 'rust-version = "1.91"', 'kio = { path = "rs/kio" }'):
            self.assertIn(kept, out)

    def test_no_members_list_is_an_error(self):
        with self.assertRaises(SystemExit):
            mv.rewrite_members('[workspace]\n', ['rs/x'])


LOCK = '''version = 4

[[package]]
name = "tokio"
version = "1.53.1"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "aa"

[[package]]
name = "ring"
version = "0.17.14"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "bb"

[[package]]
name = "moq-iroh-c"
version = "0.1.0"
'''


class LockSubset(unittest.TestCase):
    def test_dropping_entries_is_fine(self):
        cut = LOCK.split('[[package]]\nname = "ring"')[0] + '[[package]]\nname = "moq-iroh-c"\nversion = "0.1.0"\n'
        self.assertEqual(mv.lock_moved(LOCK, cut), [])

    def test_a_moved_version_or_checksum_is_caught(self):
        self.assertEqual([p[:2] for p in mv.lock_moved(LOCK, LOCK.replace('1.53.1', '1.54.0'))], [('tokio', '1.54.0')])
        self.assertEqual([p[:2] for p in mv.lock_moved(LOCK, LOCK.replace('"bb"', '"cc"'))], [('ring', '0.17.14')])

    def test_the_command_fails_on_a_move(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp, 'fork.lock'), Path(tmp, 'cut.lock')
            a.write_text(LOCK)
            b.write_text(LOCK.replace('1.53.1', '1.54.0'))
            r = subprocess.run(['python3', str(ROOT / 'tools' / 'moq_vendor.py'), 'lock-subset', str(a), str(b)],
                               capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('tokio 1.54.0', r.stderr)


def crate(vendor: Path, name: str, version: str, manifest_extra: str = '', files=None):
    d = vendor / f'{name}-{version}'
    (d / 'src').mkdir(parents=True)
    (d / 'Cargo.toml').write_text(f'[package]\nname = "{name}"\nversion = "{version}"\n{manifest_extra}')
    files = files or {'src/lib.rs': 'pub fn f() {}\n', 'big.lib': 'x' * 4096}
    sums = {}
    for rel, body in files.items():
        (d / rel).parent.mkdir(parents=True, exist_ok=True)
        (d / rel).write_text(body)
        sums[rel] = hashlib.sha256(body.encode()).hexdigest()
    (d / '.cargo-checksum.json').write_text(json.dumps({'files': sums, 'package': f'sum-{name}'}))
    return d


class Stub(unittest.TestCase):
    def test_keeps_named_crates_whole_and_stubs_the_rest(self):
        with tempfile.TemporaryDirectory() as tmp:
            v = Path(tmp)
            keep = crate(v, 'tokio', '1.53.1')
            gone = crate(v, 'windows_i686_msvc', '0.53.1',
                         'build = "build.rs"\n[lib]\npath = "src/lib.rs"\n[[bin]]\nname = "t"\npath = "src/bin/t.rs"\n'
                         '[[test]]\nname = "it"\npath = "tests/it.rs"\n',
                         {'src/lib.rs': 'x', 'build.rs': 'fn main(){}', 'lib/huge.lib': 'y' * 65536})
            before = (keep / '.cargo-checksum.json').read_text()
            kept, stubbed = mv.stub_crates(str(v), mv.parse_keep(['tokio v1.53.1', 'moq-iroh-c v0.1.0 (/w/rs/moq-iroh-c)']))
            self.assertEqual((kept, stubbed), (1, 1))
            self.assertEqual((keep / '.cargo-checksum.json').read_text(), before)
            self.assertTrue((keep / 'big.lib').exists())
            self.assertFalse((gone / 'lib').exists())
            for rel in ('src/lib.rs', 'build.rs', 'src/bin/t.rs', 'tests/it.rs'):
                self.assertEqual((gone / rel).read_text(), '', rel)
            self.assertEqual(json.loads((gone / '.cargo-checksum.json').read_text()),
                             {'files': {}, 'package': 'sum-windows_i686_msvc'})
            self.assertIn('name = "windows_i686_msvc"', (gone / 'Cargo.toml').read_text())

    def test_a_target_outside_the_crate_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            v = Path(tmp)
            crate(v, 'evil', '1.0.0', '[lib]\npath = "../../escape.rs"\n')
            with self.assertRaises(SystemExit):
                mv.stub_crates(str(v), set())

    def test_parse_keep_reads_cargo_tree_lines(self):
        self.assertEqual(mv.parse_keep(['ring v0.17.14', 'tokio v1.53.1 (*)', 'serde_derive v1.0.228 (proc-macro)', '', 'junk']),
                         {('ring', '0.17.14'), ('tokio', '1.53.1'), ('serde_derive', '1.0.228')})


class Pins(unittest.TestCase):
    def test_rust_and_lock_are_pinned_by_sha256(self):
        env = toolchain()
        self.assertRegex(env['RUST_VERSION'], r'^\d+\.\d+\.\d+$')
        self.assertRegex(env['RUST_MIN_VERSION'], r'^\d+\.\d+$')
        self.assertTrue(env['RUST_DIST_URL'].startswith('https://static.rust-lang.org/dist/'))
        for k in ('RUST_SHA256_RUSTC_X86_64_LINUX', 'RUST_SHA256_CARGO_X86_64_LINUX',
                  'RUST_SHA256_STD_X86_64_LINUX', 'RUST_SHA256_STD_X86_64_WINDOWS_GNU', 'MOQ_IROH_LOCK_SHA256'):
            self.assertRegex(env.get(k, ''), r'^[0-9a-f]{64}$', k)
        self.assertRegex(env['MOQ_IROH_COMMIT'], r'^[0-9a-f]{40}$')

    def test_spec_floor_matches_toolchain(self):
        spec = (ROOT / 'packaging' / 'ghostty-agent.spec').read_text()
        self.assertIn(f'BuildRequires:  rust >= {toolchain()["RUST_MIN_VERSION"]}', spec)
        self.assertIn('%bcond_without netlab', spec)
        self.assertIn('RUST_SYSTEM=1', spec)
        self.assertRegex(spec, r'--netlab\}%\{!\?with_netlab:--no-netlab')


def fake_component(dist: Path, name: str, version: str, target: str, files: dict[str, str]) -> str:
    """A rust dist component tarball with a working install.sh; returns its sha256."""
    base = f'{name}-{version}-{target}'
    stage = dist / 'stage' / base
    stage.mkdir(parents=True)
    for rel, body in files.items():
        p = stage / 'payload' / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)
        p.chmod(0o755)
    (stage / 'install.sh').write_text('#!/bin/sh\nset -e\nfor a; do case "$a" in --prefix=*) p="${a#--prefix=}";; esac; done\n'
                                      'mkdir -p "$p"\ncp -r "$(dirname "$0")/payload/." "$p/"\n')
    (stage / 'install.sh').chmod(0o755)
    out = dist / f'{base}.tar.xz'
    with tarfile.open(out, 'w:xz') as t:
        t.add(stage, arcname=base)
    return hashlib.sha256(out.read_bytes()).hexdigest()


class RustToolchain(unittest.TestCase):
    def run_ensure(self, env, *targets):
        cmd = 'source "$1"; shift; ensure_rust "$@"; echo "BIN=$RUST_BIN"'
        return subprocess.run(['bash', '-c', cmd, 'x', str(ROOT / 'tools' / 'rust-toolchain.sh'), *targets],
                              env=env, capture_output=True, text=True)

    def fake_rustc(self, bindir: Path, version: str, sysroot: Path):
        bindir.mkdir(parents=True, exist_ok=True)
        (bindir / 'rustc').write_text(f'#!/bin/sh\ncase "$1" in --version) echo "rustc {version} (x 2026-01-01)";; '
                                      f'--print) echo "{sysroot}";; esac\n')
        (bindir / 'cargo').write_text('#!/bin/sh\nexit 0\n')
        for f in ('rustc', 'cargo'):
            (bindir / f).chmod(0o755)

    def base_env(self, tmp: Path, path: str):
        env = {'PATH': f'{path}:/usr/bin:/bin', 'HOME': str(tmp), 'RUST_MIN_VERSION': '1.91', 'RUST_VERSION': '1.95.0'}
        return env

    def test_system_rust_must_meet_the_floor(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            self.fake_rustc(tmp / 'old', '1.90.0', tmp)
            r = self.run_ensure(dict(self.base_env(tmp, str(tmp / 'old')), RUST_SYSTEM='1'))
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('older than', r.stderr)
            self.fake_rustc(tmp / 'new', '1.98.1', tmp)
            r = self.run_ensure(dict(self.base_env(tmp, str(tmp / 'new')), RUST_SYSTEM='1'))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(f'BIN={tmp / "new"}', r.stdout)

    def test_system_rust_needs_the_asked_target(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            self.fake_rustc(tmp / 'bin', '1.95.0', tmp / 'sysroot')
            r = self.run_ensure(dict(self.base_env(tmp, str(tmp / 'bin')), RUST_SYSTEM='1'), 'x86_64-pc-windows-gnu')
            self.assertNotEqual(r.returncode, 0)
            (tmp / 'sysroot/lib/rustlib/x86_64-pc-windows-gnu/lib').mkdir(parents=True)
            r = self.run_ensure(dict(self.base_env(tmp, str(tmp / 'bin')), RUST_SYSTEM='1'), 'x86_64-pc-windows-gnu')
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_pinned_dist_is_checked_and_installed(self):
        if os.uname().sysname != 'Linux' or os.uname().machine != 'x86_64':
            self.skipTest('the pinned dist is x86_64 Linux')
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            dist = tmp / 'dist'
            dist.mkdir()
            host = 'x86_64-unknown-linux-gnu'
            home = tmp / 'rust'
            rustc = (f'#!/bin/sh\ncase "$1" in --version) echo "rustc 1.95.0 (x)";; --print) echo "{home}";; esac\n')
            sums = {
                'RUST_SHA256_RUSTC_X86_64_LINUX': fake_component(dist, 'rustc', '1.95.0', host, {'bin/rustc': rustc}),
                'RUST_SHA256_CARGO_X86_64_LINUX': fake_component(dist, 'cargo', '1.95.0', host, {'bin/cargo': '#!/bin/sh\n'}),
                'RUST_SHA256_STD_X86_64_LINUX': fake_component(dist, 'rust-std', '1.95.0', host, {f'lib/rustlib/{host}/lib/x': ''}),
                'RUST_SHA256_STD_X86_64_WINDOWS_GNU': fake_component(dist, 'rust-std', '1.95.0', 'x86_64-pc-windows-gnu',
                                                                    {'lib/rustlib/x86_64-pc-windows-gnu/lib/x': ''}),
            }
            env = dict(self.base_env(tmp, '/nonexistent'), RUST_DIST_URL=f'file://{dist}', RUST_HOME=str(home), **sums)
            bad = dict(env, RUST_SHA256_CARGO_X86_64_LINUX='0' * 64)
            r = self.run_ensure(bad)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('checksum mismatch for cargo-1.95.0', r.stderr)
            import shutil
            shutil.rmtree(home, ignore_errors=True)
            r = self.run_ensure(env, 'x86_64-pc-windows-gnu')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(f'BIN={home}/bin', r.stdout)
            self.assertTrue((home / 'lib/rustlib/x86_64-pc-windows-gnu/lib/x').exists())


class SourceTarball(unittest.TestCase):
    def test_every_script_the_agent_build_sources_is_packed(self):
        """tools/package-agent.sh packs a fixed list of tools; a script that
        build-agent.sh (or the spec) reaches but the list misses breaks rpmbuild."""
        pack = (ROOT / 'tools' / 'package-agent.sh').read_text()
        listed = set(re.findall(r'(tools/[\w.-]+\.sh|toolchain\.env)', pack.split('git ls-files -z --', 1)[1].split(')', 1)[0]))
        todo, seen = ['tools/build-agent.sh', 'tools/build-moq-iroh.sh'], set()
        while todo:
            f = todo.pop()
            if f in seen:
                continue
            seen.add(f)
            text = (ROOT / f).read_text()
            for m in re.findall(r'source "\$ROOT/((?:tools/[\w.-]+\.sh)|toolchain\.env)"', text):
                todo.append(m)
        missing = sorted(seen - listed)
        self.assertEqual(missing, [], 'reached by the agent build but not packed by tools/package-agent.sh')

    def test_spec_scripts_are_packed(self):
        spec = (ROOT / 'packaging' / 'ghostty-agent.spec').read_text()
        pack = (ROOT / 'tools' / 'package-agent.sh').read_text()
        for script in set(re.findall(r'\./(tools/[\w.-]+\.sh)', spec)):
            self.assertIn(script, pack, script)
        self.assertIn('vendor/moq-iroh-src', pack)
        self.assertIn('--exclude=./target', pack)


if __name__ == '__main__':
    unittest.main()
