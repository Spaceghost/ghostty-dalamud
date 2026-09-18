from __future__ import annotations
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def bundle_module():
    spec = importlib.util.spec_from_file_location('fetch_dalamud', ROOT / 'tools' / 'fetch-dalamud.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def archive(entries):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w') as z:
        for name, data in entries.items():
            z.writestr(name, data)
    data = out.getvalue()
    return data, hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()


class Portability(unittest.TestCase):
    def test_shell_syntax(self):
        scripts = list((ROOT / 'tools').glob('*.sh')) + list((ROOT / 'tests').glob('*.sh'))
        for script in scripts:
            with self.subTest(script=script.name):
                subprocess.run(['bash', '-n', str(script)], check=True)

    def test_executable_launcher_does_not_skip_compiler_build(self):
        with tempfile.TemporaryDirectory(prefix='ghostty space ') as tmp:
            root = Path(tmp)
            vendor = root / 'vendor' / 'nelua-lang'
            vendor.mkdir(parents=True)
            launcher = vendor / 'nelua'
            launcher.write_text('#!/bin/sh\nexec "$(dirname "$0")/nelua-lua" "$@"\n')
            launcher.chmod(0o755)
            (vendor / 'Makefile').write_text('all: nelua-lua\nnelua-lua:\n\tprintf "#!/bin/sh\\nexit 0\\n" > nelua-lua\n\tchmod +x nelua-lua\n')
            self.assertFalse((vendor / 'nelua-lua').exists())
            env = dict(os.environ, ROOT=str(root), JOBS='1')
            command = 'source "$1"; build_nelua; "$ROOT/vendor/nelua-lang/nelua" --version'
            result = subprocess.run(['bash', '-eu', '-c', command, 'test', str(ROOT / 'tools' / 'build-common.sh')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(os.access(vendor / 'nelua-lua', os.X_OK))

    def test_verified_cache_and_tampering(self):
        module = bundle_module()
        data, expected = archive({'Dalamud.dll': b'test fixture', 'Nested/other.dll': b'second fixture'})
        url = 'https://raw.githubusercontent.com/goatcorp/dalamud-distrib/' + '0' * 40 + '/latest.zip'
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'refs'
            with patch.object(module.urllib.request, 'urlopen', return_value=io.BytesIO(data)):
                module.install(url, expected, target)
            self.assertTrue(module.cached(target, expected))
            with patch.object(module.urllib.request, 'urlopen', side_effect=AssertionError('should not download')):
                module.install(url, expected, target)
            (target / 'Dalamud.dll').write_bytes(b'tampered')
            self.assertFalse(module.cached(target, expected))
            with self.assertRaises(RuntimeError):
                module.install(url, expected, target)

    def test_wrong_bundle_hash_is_rejected(self):
        module = bundle_module()
        data, _ = archive({'Dalamud.dll': b'test fixture'})
        url = 'https://raw.githubusercontent.com/goatcorp/dalamud-distrib/' + '0' * 40 + '/latest.zip'
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'refs'
            with patch.object(module.urllib.request, 'urlopen', return_value=io.BytesIO(data)):
                with self.assertRaises(RuntimeError):
                    module.install(url, '0' * 40, target)
            self.assertFalse(target.exists())

    def test_archive_traversal_is_rejected(self):
        module = bundle_module()
        data, expected = archive({'Dalamud.dll': b'test fixture', '../escape': b'no'})
        url = 'https://raw.githubusercontent.com/goatcorp/dalamud-distrib/' + '0' * 40 + '/latest.zip'
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'refs'
            with patch.object(module.urllib.request, 'urlopen', return_value=io.BytesIO(data)):
                with self.assertRaises(RuntimeError):
                    module.install(url, expected, target)
            self.assertFalse((Path(tmp) / 'escape').exists())


if __name__ == '__main__':
    unittest.main()
