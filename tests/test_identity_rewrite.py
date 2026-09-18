from __future__ import annotations
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / 'tools' / 'rewrite-identity.py'
spec = importlib.util.spec_from_file_location('rewrite_identity', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IdentityRewrite(unittest.TestCase):
    def test_history_deleted_files_and_attribution(self):
        with tempfile.TemporaryDirectory() as directory:
            old = Path.cwd()
            os.chdir(directory)
            try:
                subprocess.run(['git', 'init', '-q', '-b', 'main'], check=True)
                def g(*args):
                    return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL)
                g('config', 'user.name', 'Private Test Maintainer')
                g('config', 'user.email', 'private-test@example.invalid')
                Path('credits.txt').write_text('Private Test Maintainer <private-test@example.invalid>')
                Path('binary.dat').write_bytes(b'\0nonidentifying-binary-data')
                Path('Private Test Maintainer.txt').write_text('retained content')
                g('add', '.')
                g('commit', '-qm', 'Initialize fixture')
                Path('credits.txt').unlink()
                Path('other.txt').write_text('An unrelated contributor stays credited.')
                g('add', '-A')
                g('commit', '-qm', 'Delete private-test@example.invalid from the working tree')
                g('config', 'user.name', 'Other Contributor')
                g('config', 'user.email', 'other@example.invalid')
                Path('other.txt').write_text('An unrelated contributor still stays credited.')
                g('add', '.')
                g('commit', '-qm', 'Unrelated contribution')
                head = g('rev-parse', 'HEAD').strip().decode()
                new, commits, objects = module.rewrite(head, b'Spaceghost', b'251370+Spaceghost@users.noreply.github.com')
                self.assertEqual(commits, 3)
                self.assertGreater(objects, 3)
                self.assertNotEqual(head, new)
                for entry in g('rev-list', '--objects', new).splitlines():
                    oid = entry.split()[0].decode()
                    typ = g('cat-file', '-t', oid).strip().decode()
                    data = g('cat-file', typ, oid)
                    self.assertNotIn(b'Private Test Maintainer', data)
                    self.assertNotIn(b'private-test@example.invalid', data)
                log = g('log', '--format=%an <%ae>', new)
                self.assertIn(b'Other Contributor <other@example.invalid>', log)
                self.assertIn(b'Spaceghost <251370+Spaceghost@users.noreply.github.com>', log)
                self.assertEqual(g('rev-list', '--count', new).strip(), b'3')
                self.assertEqual(g('show', new + ':binary.dat'), b'\0nonidentifying-binary-data')
                g('fsck', '--no-reflogs', '--connectivity-only', new)
            finally:
                os.chdir(old)

    def test_binary_identity_is_not_blindly_rewritten(self):
        with tempfile.TemporaryDirectory() as directory:
            old = Path.cwd()
            os.chdir(directory)
            try:
                def g(*args):
                    return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL)
                g('init', '-q', '-b', 'main')
                g('config', 'user.name', 'Private Test Maintainer')
                g('config', 'user.email', 'private-test@example.invalid')
                Path('binary.dat').write_bytes(b'\0prefix' + 'Private Test Maintainer'.encode('utf-16le'))
                g('add', '.')
                g('commit', '-qm', 'Binary fixture')
                head = g('rev-parse', 'HEAD').strip().decode()
                with self.assertRaisesRegex(RuntimeError, 'binary'):
                    module.rewrite(head, b'Spaceghost', b'251370+Spaceghost@users.noreply.github.com')
                self.assertEqual(g('rev-parse', 'HEAD').strip().decode(), head)
            finally:
                os.chdir(old)


if __name__ == '__main__':
    unittest.main()
