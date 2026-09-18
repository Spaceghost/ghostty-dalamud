"""Private-install and readiness checks, using synthetic PE/header fixtures only."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import candidate
import release


def pe():
    data = bytearray(256)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 64)
    data[64:68] = b"PE\0\0"
    struct.pack_into("<H", data, 68, 0x8664)
    struct.pack_into("<H", data, 86, 0x2000)
    struct.pack_into("<H", data, 88, 0x20B)
    return bytes(data)


def manifest():
    return {"Author": "Spaceghost", "Name": "Ghostty", "Description": "fixture",
            "Punchline": "fixture", "InternalName": "GhosttyDalamud",
            "AssemblyVersion": "0.2.0.0", "DalamudApiLevel": 15,
            "RepoUrl": release.REPOSITORY}


def filled_record(commit, digest):
    # Deliberately synthetic evidence for schema tests, not an actual test record.
    return {"schema": 1, "source_commit": commit, "source_dirty": False,
            "package_sha256": digest, "assembly_version": "0.2.0.0", "api": 15,
            "reviewer": "fixture-reviewer", "ai_level": "Auto", "ai_notes": "test fixture",
            "checks": {k: {"passed": True, "evidence": "test fixture"} for k in candidate.CHECKS},
            "runtime": {p: {"game_version": "fixture", "dalamud_version": "fixture", "tested_at": "fixture",
                        "checks": {k: True for k in candidate.RUNTIME_CHECKS}}
                        for p in ("windows", "wine")}}


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.package = self.root / "candidate.zip"
        self.destination = self.root / "new install"
        self.files = {n: b"-- fixture\n" for n in release.PAYLOAD}
        self.files["GhosttyDalamud.json"] = json.dumps(manifest()).encode()
        self.files["GhosttyDalamud.dll"] = pe()
        self.files["ghostty_core.dll"] = pe()
        self.archive()
        self.digest = hashlib.sha256(self.package.read_bytes()).hexdigest()

    def archive(self):
        with zipfile.ZipFile(self.package, "w") as archive:
            for name, data in self.files.items():
                archive.writestr(name, data)

    def test_fresh_install_exact_payload(self):
        result = candidate.install(self.package, self.destination, self.digest)
        actual = {p.relative_to(self.destination).as_posix() for p in self.destination.rglob("*") if p.is_file()}
        self.assertEqual(actual, release.PAYLOAD)
        self.assertEqual(result["api"], 15)
        self.assertEqual(result["package_sha256"], self.digest)
        self.assertFalse((self.destination / "ghostty_loader.dll").exists())

    def test_existing_install_is_never_overwritten(self):
        self.destination.mkdir()
        marker = self.destination / "ghostty_loader.dll"
        marker.write_bytes(b"existing")
        with self.assertRaises(FileExistsError):
            candidate.install(self.package, self.destination)
        self.assertEqual(marker.read_bytes(), b"existing")

    def test_wrong_checksum_creates_no_install(self):
        with self.assertRaisesRegex(release.ReleaseError, "SHA-256"):
            candidate.install(self.package, self.destination, "0" * 64)
        self.assertFalse(self.destination.exists())

    def test_private_configuration_is_rejected(self):
        for name in ("token", "settings.lua", "world-state.lua", "lua/private.lua", "GhosttyDalamud.pdb"):
            with self.subTest(name=name):
                self.files[name] = b"not-for-distribution"
                self.archive()
                with self.assertRaises(release.ReleaseError):
                    candidate.install(self.package, self.destination)
                self.assertFalse(self.destination.exists())
                del self.files[name]

    def test_windows_separators_extract_normally(self):
        self.files = {n.replace("/", "\\"): d for n, d in self.files.items()}
        self.archive()
        candidate.install(self.package, self.destination)
        self.assertTrue((self.destination / "lua/init.lua").is_file())

    def test_symlink_destination_is_rejected(self):
        target = self.root / "target"
        target.mkdir()
        self.destination.symlink_to(target, target_is_directory=True)
        with self.assertRaises(FileExistsError):
            candidate.install(self.package, self.destination)
        self.assertEqual(list(target.iterdir()), [])

    def test_unverified_record_cannot_pass(self):
        record = filled_record("a" * 40, self.digest)
        for item in record["checks"].values():
            item["passed"] = None
        errors = candidate.evidence_errors(record, "a" * 40, self.digest, manifest())
        self.assertTrue(all("unverified: " + name in errors for name in candidate.CHECKS))

    def test_complete_fixture_evidence_schema(self):
        record = filled_record("a" * 40, self.digest)
        self.assertEqual(candidate.evidence_errors(record, "a" * 40, self.digest, manifest()), [])

    def test_wrong_commit_and_package_are_blocked(self):
        record = filled_record("a" * 40, self.digest)
        errors = candidate.evidence_errors(record, "b" * 40, "0" * 64, manifest())
        self.assertTrue(any("source commit" in e for e in errors))
        self.assertTrue(any("different package" in e for e in errors))

    def test_dirty_source_is_blocked(self):
        record = filled_record("a" * 40, self.digest)
        for value in (True, None, "false", 0):
            record["source_dirty"] = value
            self.assertTrue(any("dirty" in e for e in candidate.evidence_errors(record, "a" * 40, self.digest, manifest())))

    def test_runtime_results_must_be_actual_booleans(self):
        record = filled_record("a" * 40, self.digest)
        for value in (None, False, "pass", "true", 1):
            record["runtime"]["wine"]["checks"]["clean_install"] = value
            self.assertIn("wine: unverified clean_install", candidate.evidence_errors(record, "a" * 40, self.digest, manifest()))

    def test_runtime_version_and_human_reviewer_are_required(self):
        record = filled_record("a" * 40, self.digest)
        record["reviewer"] = ""
        record["runtime"]["windows"]["game_version"] = ""
        errors = candidate.evidence_errors(record, "a" * 40, self.digest, manifest())
        self.assertTrue(any("human review" in e for e in errors))
        self.assertIn("windows: missing game_version", errors)

    def test_evidence_details_and_ai_disclosure_are_required(self):
        record = filled_record("a" * 40, self.digest)
        record["checks"]["gameplay_review"]["evidence"] = ""
        record["ai_level"] = "None"
        errors = candidate.evidence_errors(record, "a" * 40, self.digest, manifest())
        self.assertIn("unverified: gameplay_review", errors)
        self.assertTrue(any("AI involvement" in e for e in errors))

    def test_malformed_evidence_fails_closed(self):
        self.assertTrue(candidate.evidence_errors([], "a" * 40, self.digest, manifest()))
        record = filled_record("a" * 40, self.digest)
        record.update(checks=[], runtime=[])
        self.assertTrue(candidate.evidence_errors(record, "a" * 40, self.digest, manifest()))

    def test_png_header_dimensions(self):
        icon = self.root / "icon.png"
        for width, height in ((64, 64), (512, 512)):
            icon.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\0\0\0\rIHDR" + struct.pack(">II", width, height) + b"\0" * 9)
            self.assertEqual(candidate.png_size(icon), (width, height))
        for width, height in ((32, 32), (513, 513), (128, 64)):
            icon.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\0\0\0\rIHDR" + struct.pack(">II", width, height) + b"\0" * 9)
            with self.assertRaises(release.ReleaseError):
                candidate.png_size(icon)

    def test_record_does_not_overwrite_prior_results(self):
        output = self.root / "record.json"
        candidate.write_new(output, {"first": True})
        with self.assertRaises(FileExistsError):
            candidate.write_new(output, {"first": False})
        self.assertEqual(json.loads(output.read_text()), {"first": True})

    def test_real_git_record_starts_unverified(self):
        repo = self.root / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "README.md").write_text("fixture\n")
        subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Spaceghost", "-c",
                        "user.email=251370+Spaceghost@users.noreply.github.com", "commit", "-qm", "fixture"], check=True)
        result = candidate.record(self.package, repo)
        self.assertFalse(result["source_dirty"])
        self.assertEqual(len(result["source_commit"]), 40)
        self.assertTrue(all(v["passed"] is None for v in result["checks"].values()))
        self.assertEqual(result["reviewer"], "")
        (repo / "uncommitted.txt").write_text("fixture\n")
        self.assertTrue(candidate.record(self.package, repo)["source_dirty"])


if __name__ == "__main__":
    unittest.main()
