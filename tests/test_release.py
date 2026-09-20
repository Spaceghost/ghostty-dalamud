"""Packaging contract tests. Synthetic PE fixtures do not establish game compatibility."""
import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path
import struct
import tempfile
import tomllib
import unittest
import warnings
import zipfile

SPEC = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "tools/release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def manifest():
    return {"Author": "Spaceghost", "Name": "Ghostty", "Description": "Terminal",
            "Punchline": "Terminal", "InternalName": "GhosttyDalamud",
            "AssemblyVersion": "0.2.0.0", "DalamudApiLevel": 15,
            "RepoUrl": release.REPOSITORY}


def pe(machine=0x8664, magic=0x20B):
    data = bytearray(256)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 64)
    data[64:68] = b"PE\0\0"
    struct.pack_into("<H", data, 68, machine)
    struct.pack_into("<H", data, 86, 0x2000)
    struct.pack_into("<H", data, 88, magic)
    return bytes(data)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "latest.zip"
        self.files = {name: b"-- shipped module\n" for name in release.PAYLOAD}
        self.files["GhosttyDalamud.json"] = json.dumps(manifest()).encode()
        self.files["GhosttyDalamud.dll"] = pe()
        self.files["ghostty_core.dll"] = pe()

    def archive(self, extra=()):
        with zipfile.ZipFile(self.path, "w") as out:
            for name, data in self.files.items():
                out.writestr(name, data)
            for name, data in extra:
                out.writestr(name, data)
        return self.path

    def test_complete_package(self):
        actual, hashes = release.inspect_package(self.archive(), manifest())
        self.assertEqual(actual, manifest())
        self.assertEqual(set(hashes), release.PAYLOAD)
        self.assertTrue(all(len(h) == 64 for h in hashes.values()))

    def test_missing_core(self):
        del self.files["ghostty_core.dll"]
        with self.assertRaisesRegex(release.ReleaseError, "missing payload"):
            release.inspect_package(self.archive())

    def test_missing_lua_module(self):
        del self.files["lua/migrate.lua"]
        with self.assertRaisesRegex(release.ReleaseError, "missing payload"):
            release.inspect_package(self.archive())

    def test_never_package_host_debug_or_user_files(self):
        for name in ("Dalamud.dll", "Lumina.dll", "Umbra.Ghostty.dll", "ghostty_loader.dll",
                     "settings.lua", "world-state.lua", "token", "GhosttyDalamud.pdb",
                     "ghostty-agent", "lua/private.lua"):
            with self.subTest(name=name), self.assertRaisesRegex(release.ReleaseError, "unapproved"):
                release.inspect_package(self.archive([(name, b"no")]))

    def test_traversal_and_absolute_paths(self):
        for name in ("../token", "/token", "C:/token", "lua/../../token", "lua/../token",
                     "lua//init.lua", "./token", "lua/./init.lua"):
            with self.subTest(name=name), self.assertRaisesRegex(release.ReleaseError, "unsafe"):
                release.inspect_package(self.archive([(name, b"no")]))

    def test_windows_zip_separators(self):
        self.files = {name.replace("/", "\\"): data for name, data in self.files.items()}
        _, hashes = release.inspect_package(self.archive())
        self.assertEqual(set(hashes), release.PAYLOAD)

    def test_duplicate_case_insensitive(self):
        with self.assertRaisesRegex(release.ReleaseError, "duplicate"):
            release.inspect_package(self.archive([("ghosttydalamud.dll", pe())]))

    def test_exact_duplicate(self):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            path = self.archive([("GhosttyDalamud.dll", pe())])
        with self.assertRaisesRegex(release.ReleaseError, "duplicate"):
            release.inspect_package(path)

    def test_symlink(self):
        self.archive()
        with zipfile.ZipFile(self.path, "a") as out:
            member = zipfile.ZipInfo("link")
            member.create_system = 3
            member.external_attr = 0o120777 << 16
            out.writestr(member, "/etc/passwd")
        with self.assertRaisesRegex(release.ReleaseError, "symlink"):
            release.inspect_package(self.path)

    def test_x86_or_non_pe_dll(self):
        for data in (b"not a DLL", pe(0x14C, 0x10B), b"MZ" + b"\x00" * 62):
            self.files["ghostty_core.dll"] = data
            with self.subTest(data=data[:4]), self.assertRaises(release.ReleaseError):
                release.inspect_package(self.archive())

    def test_manifest_version_mismatch(self):
        source = manifest()
        source["AssemblyVersion"] = "0.3.0.0"
        with self.assertRaisesRegex(release.ReleaseError, "differs from source"):
            release.inspect_package(self.archive(), source)

    def test_manifest_api_mismatch(self):
        source = manifest()
        source["DalamudApiLevel"] = 16
        with self.assertRaisesRegex(release.ReleaseError, "differs from source"):
            release.inspect_package(self.archive(), source)

    def test_invalid_manifest(self):
        for key, value in (("Author", "private name"), ("RepoUrl", "http://wrong"),
                           ("AssemblyVersion", "1.2"), ("AssemblyVersion", "1.2.3.65535"),
                           ("InternalName", "Other"), ("DalamudApiLevel", True),
                           ("Description", "")):
            candidate = manifest()
            candidate[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(release.ReleaseError):
                release.validate_manifest(candidate)

    def test_testing_repository(self):
        entry = release.repository_entry(manifest(), "https://example.org/v0.2.0.0/latest.zip", 1, "testing")[0]
        self.assertTrue(entry["IsTestingExclusive"])
        self.assertEqual(entry["TestingAssemblyVersion"], "0.2.0.0")
        self.assertEqual(entry["TestingDalamudApiLevel"], 15)
        self.assertEqual(entry["DownloadLinkInstall"], entry["DownloadLinkTesting"])

    def test_stable_is_explicit(self):
        entry = release.repository_entry(manifest(), "https://example.org/v1/plugin.zip", 1, "stable")[0]
        self.assertFalse(entry["IsTestingExclusive"])
        self.assertNotIn("TestingAssemblyVersion", entry)

    def test_no_insecure_credentialed_or_mutable_urls(self):
        for url in ("http://example.org/a.zip", "https://user:secret@example.org/a.zip",
                    "https://example.org/a.zip?token=secret", "https://example.org/a.zip#fragment",
                    "https://example.org/latest/download/plugin.zip", "https://example.org/a.exe"):
            with self.subTest(url=url), self.assertRaises(release.ReleaseError):
                release.download_url(url)

    def test_submission_roundtrip(self):
        result = tomllib.loads(release.submission_manifest("a" * 40, 'Initial "test"\nSecond line'))
        self.assertEqual(result["plugin"]["owners"], ["Spaceghost"])
        self.assertEqual(result["plugin"]["project_path"], "shim/GhosttyDalamud")
        self.assertEqual(result["plugin"]["commit"], "a" * 40)

    def test_submission_never_points_at_a_branch_or_placeholder(self):
        for commit in ("main", "HEAD", "@COMMIT@", "abcd", "0" * 40):
            with self.subTest(commit=commit), self.assertRaises(release.ReleaseError):
                release.submission_manifest(commit, "test")


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "tools").mkdir()
        self.script = self.root / "tools/bootstrap-nelua.sh"
        shutil.copyfile(Path(__file__).resolve().parents[1] / "tools/bootstrap-nelua.sh", self.script)

    def run_bootstrap(self, jobs="1"):
        return subprocess.run(["bash", str(self.script)], text=True, capture_output=True,
                              env={**os.environ, "JOBS": jobs}, timeout=15)

    def sources(self):
        vendor = self.root / "vendor/nelua-lang"
        vendor.mkdir(parents=True)
        (vendor / "Makefile").write_text("nelua-lua: input\n\tcp input nelua-lua\n\tchmod +x nelua-lua\n")
        (vendor / "input").write_text("#!/bin/sh\nprintf 'fixture-version\\n'\n")
        launcher = vendor / "nelua"
        launcher.write_text('#!/bin/sh\nexec "$(dirname "$0")/nelua-lua" "$@"\n')
        launcher.chmod(0o755)
        return vendor

    def test_fresh_clone_executable_launcher_still_builds_interpreter(self):
        vendor = self.sources()
        self.assertFalse((vendor / "nelua-lua").exists())
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fixture-version", result.stdout)
        self.assertTrue((vendor / "nelua-lua").exists())

    def test_missing_sources_fail_clearly(self):
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sources missing", result.stderr)

    def test_invalid_job_count_is_rejected(self):
        self.sources()
        result = self.run_bootstrap("0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("positive integer", result.stderr)


if __name__ == "__main__":
    unittest.main()
