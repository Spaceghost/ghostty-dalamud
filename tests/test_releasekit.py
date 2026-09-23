"""tools/releasekit.py: the testing channel cutting itself, and the per-channel history.

Each test builds a throwaway repository with the files releasekit reads (release.conf,
a manifest, the version files and a stand-in changelog tool), an origin/master ref and a
history of master commits and tags, then points the module at it. No network, no gh.
"""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

CONF = """\
NAME=Ghostty
INTERNAL_NAME=GhosttyDalamud
REPO=Spaceghost/ghostty-dalamud
MANIFEST=plugin.json
VERSION_FILES=plugin.json agent.spec
BASE_VERSION_FILES=buildinfo.txt
CHANGELOG_TOOL=changelog.py
CHANGELOG_FILES=changelog.json
BANNER=banner.png
SITE=https://example.invalid/
CI_WORKFLOWS=CI
"""

# prints changelog.json as `--dump` would, so each test chooses the entries
CHANGELOG_TOOL = """\
import json, sys
print(open("changelog.json").read())
"""


def load():
    spec = importlib.util.spec_from_file_location("releasekit_under_test", REPO / "tools" / "releasekit.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Repo:
    def __init__(self, root: Path):
        self.root = root
        self.env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
                        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid",
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.git("init", "-q", "-b", "master")
        (root / "tools").mkdir()
        (root / "tools" / "release.conf").write_text(CONF)
        (root / "changelog.py").write_text(CHANGELOG_TOOL)
        self.entries([{"status": "beta", "text": "Something new."}])
        self.version("0.3.0.0")
        self.commit("Start")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def entries(self, items):
        (self.root / "changelog.json").write_text(json.dumps([{"version": "next", "items": items}]))

    def version(self, v4: str):
        v3 = v4.rsplit(".", 1)[0]
        (self.root / "plugin.json").write_text(json.dumps({"AssemblyVersion": v4}, indent=2) + "\n")
        (self.root / "agent.spec").write_text(f"Version:        {v4}\n")
        (self.root / "buildinfo.txt").write_text(f"global version = '{v3}'\n")

    def commit(self, subject: str, path: str = "code.txt") -> str:
        f = self.root / path
        f.write_text(f.read_text() + subject + "\n" if f.exists() else subject + "\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", subject)
        return self.git("rev-parse", "HEAD")

    def tag(self, name: str, ref: str = "HEAD"):
        self.git("tag", "-a", name, "-m", name, ref)

    def publish(self):
        """What origin/master is: the ref check-tag and auto-test compare against."""
        self.git("update-ref", "refs/remotes/origin/master", "master")


class ReleaseKitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        (Path(self.tmp.name) / "repo").mkdir()
        self.repo = Repo(Path(self.tmp.name) / "repo")
        self.kit = load()
        self.kit.ROOT = self.repo.root
        self.c = self.kit.conf()
        self._env = dict(os.environ)
        os.environ.update({k: v for k, v in self.repo.env.items() if k.startswith("GIT_")})
        os.environ.pop("GITHUB_OUTPUT", None)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)
        self.tmp.cleanup()

    def auto(self, sha: str) -> str:
        """Run auto-test on `sha` checked out detached, as the workflow does; the tag or ''."""
        self.repo.publish()
        self.repo.git("checkout", "-q", "--detach", sha)
        out = Path(self.tmp.name) / "out"
        out.write_text("")
        os.environ["GITHUB_OUTPUT"] = str(out)
        try:
            self.kit.auto_test(self.c, sha, push=False)
        finally:
            os.environ.pop("GITHUB_OUTPUT", None)
            self.repo.git("checkout", "-q", "master")
        values = dict(line.split("=", 1) for line in out.read_text().splitlines())
        return values["tag"]

    # -- versions -------------------------------------------------------------------

    def test_after_a_stable_release_the_next_patch_is_tested(self):
        self.repo.tag("v0.3.0")
        self.repo.commit("A feature")
        v, v4 = self.kit.plan(self.c, "test", None)
        self.assertEqual((v.tag, v4), ("v0.3.1-test.1", "0.3.1.1"))

    def test_auto_builds_count_on_from_the_tags_not_the_manifest(self):
        self.repo.tag("v0.3.0")
        a = self.repo.commit("First feature")
        self.assertEqual(self.auto(a), "v0.3.1-test.1")
        b = self.repo.commit("Second feature")
        self.assertEqual(self.auto(b), "v0.3.1-test.2")
        # master was never written to: its manifest is where it was
        self.assertEqual(json.loads((self.repo.root / "plugin.json").read_text())["AssemblyVersion"], "0.3.0.0")
        # and a manual test build afterwards still moves forward
        v, v4 = self.kit.plan(self.c, "test", None)
        self.assertEqual((v.tag, v4), ("v0.3.1-test.3", "0.3.1.3"))

    def test_the_auto_tag_is_a_version_commit_on_top_of_master(self):
        self.repo.tag("v0.3.0")
        sha = self.repo.commit("A feature")
        tag = self.auto(sha)
        self.assertEqual(self.repo.git("rev-parse", f"{tag}^^{{commit}}"), sha)
        self.assertEqual(self.repo.git("log", "-1", "--format=%s", tag), f"Release {tag}")
        touched = set(self.repo.git("diff", "--name-only", sha, tag).splitlines())
        self.assertEqual(touched, {"plugin.json", "agent.spec", "buildinfo.txt"})
        self.assertEqual(json.loads(self.repo.git("show", f"{tag}:plugin.json"))["AssemblyVersion"], "0.3.1.1")
        self.assertIn("0.3.1'", self.repo.git("show", f"{tag}:buildinfo.txt"))
        # the release workflow's own check accepts it
        self.repo.git("checkout", "-q", "--detach", tag)
        self.kit.check_tag(self.c, self.kit.Version(tag))

    def test_check_tag_refuses_an_off_master_commit_that_changes_code(self):
        self.repo.tag("v0.3.0")
        self.repo.commit("A feature")
        self.repo.publish()
        self.repo.git("checkout", "-q", "--detach")
        self.repo.version("0.3.1.1")
        self.repo.commit("Release v0.3.1-test.1", path="sneaky.txt")
        with self.assertRaises(SystemExit) as err:
            self.kit.check_tag(self.c, self.kit.Version("v0.3.1-test.1"))
        self.assertIn("not on master", str(err.exception))

    def test_a_stable_tag_must_be_on_master_itself(self):
        self.repo.tag("v0.3.0")
        self.repo.commit("A feature")
        self.repo.publish()
        self.repo.git("checkout", "-q", "--detach")
        self.repo.version("0.3.1.0")
        self.repo.git("commit", "-q", "-am", "Release v0.3.1")
        with self.assertRaises(SystemExit):
            self.kit.check_tag(self.c, self.kit.Version("v0.3.1"))

    # -- what is cut, and what is not -----------------------------------------------

    def test_nothing_is_cut_for_a_commit_already_released(self):
        self.repo.tag("v0.3.0")
        sha = self.repo.commit("A feature")
        self.assertEqual(self.auto(sha), "v0.3.1-test.1")
        self.assertEqual(self.auto(sha), "")  # CI finishing twice, or late

    def test_nothing_is_cut_for_a_manual_release_commit(self):
        self.repo.tag("v0.3.0")
        self.repo.commit("A feature")
        self.repo.version("0.3.1.1")
        sha = self.repo.commit("Release v0.3.1-test.1")
        self.repo.tag("v0.3.1-test.1")
        self.assertEqual(self.auto(sha), "")

    def test_an_older_green_commit_is_not_cut_after_a_newer_one(self):
        self.repo.tag("v0.3.0")
        old = self.repo.commit("First feature")
        new = self.repo.commit("Second feature")
        self.assertEqual(self.auto(new), "v0.3.1-test.1")
        self.assertEqual(self.auto(old), "")

    def test_a_commit_not_on_master_is_refused(self):
        self.repo.tag("v0.3.0")
        self.repo.publish()
        self.repo.git("checkout", "-q", "-b", "topic")
        sha = self.repo.commit("Unmerged work")
        self.repo.git("checkout", "-q", "master")
        with self.assertRaises(SystemExit):
            self.kit.auto_test(self.c, sha, push=False)

    def test_a_build_with_no_changelog_entries_still_ships_what_merged(self):
        self.repo.tag("v0.3.0")
        self.repo.entries([])
        sha = self.repo.commit("A fix nobody wrote up")
        tag = self.auto(sha)
        self.assertEqual(tag, "v0.3.1-test.1")
        notes = self.kit.notes(self.c, self.kit.Version(tag), None)
        self.assertIn("A fix nobody wrote up", notes)
        self.assertIn("no entries for this build yet", notes)

    # -- the history, per channel ---------------------------------------------------

    def test_testing_notes_list_since_the_last_test_build_and_since_stable(self):
        self.repo.tag("v0.3.0")
        a = self.repo.commit("First feature (#12)")
        self.assertEqual(self.auto(a), "v0.3.1-test.1")
        self.repo.commit("Second feature (#13)")
        c = self.repo.commit("A direct fix")
        tag = self.auto(c)
        text = self.kit.changes(self.c, self.kit.Version(tag))
        since_test, since_stable = text.split("### Since the last stable release, v0.3.0")
        self.assertIn("Since the previous test build, v0.3.1-test.1", since_test)
        self.assertNotIn("First feature", since_test)
        self.assertIn("* Second feature (#13)", since_test)
        self.assertIn("A direct fix ([`", since_test)
        for subject in ("First feature (#12)", "Second feature (#13)", "A direct fix"):
            self.assertIn(subject, since_stable)
        self.assertNotIn("Release v", text)

    def test_stable_notes_list_since_the_last_stable_only(self):
        self.repo.tag("v0.3.0")
        a = self.repo.commit("First feature")
        self.auto(a)
        self.repo.commit("Second feature")
        self.repo.version("0.3.1.2")
        self.repo.commit("Release v0.3.1")
        self.repo.tag("v0.3.1")
        text = self.kit.changes(self.c, self.kit.Version("v0.3.1"))
        self.assertTrue(text.startswith("### Since the last stable release, v0.3.0"))
        self.assertNotIn("previous test build", text)
        self.assertIn("First feature", text)
        self.assertIn("Second feature", text)

    def test_installer_notes_name_what_merged_since_the_last_build(self):
        self.repo.tag("v0.3.0")
        tag = self.auto(self.repo.commit("A feature (#7)"))
        self.repo.git("checkout", "-q", tag)
        text = self.kit.installer_notes(self.c, self.kit.Version(tag))
        self.assertIn("Merged since v0.3.0:", text)
        self.assertIn("- A feature", text)
        self.assertNotIn("(#7)", text)

    def test_tag_order_puts_tests_before_their_stable(self):
        order = sorted(["v0.3.1", "v0.3.1-test.2", "v0.3.0", "v0.3.1-test.10"], key=self.kit.tag_order)
        self.assertEqual(order, ["v0.3.0", "v0.3.1-test.2", "v0.3.1-test.10", "v0.3.1"])


class WorkflowTests(unittest.TestCase):
    """The workflow wiring the tests above cannot run."""

    def test_testing_channel_only_follows_green_pushes_to_master(self):
        text = (REPO / ".github" / "workflows" / "testing-channel.yml").read_text()
        for needle in ("workflows: [CI]", "conclusion == 'success'", "event == 'push'",
                       "head_branch == 'master'", "head_repository.full_name == github.repository",
                       "cancel-in-progress: false", "uses: ./.github/workflows/release.yml",
                       "auto-test --sha"):
            self.assertIn(needle, text)
        self.assertNotIn("pull_request_target", text)

    def test_release_workflow_publishes_the_tag_it_is_given(self):
        text = (REPO / ".github" / "workflows" / "release.yml").read_text()
        self.assertIn("workflow_call:", text)
        self.assertIn("TAG: ${{ inputs.tag || github.ref_name }}", text)
        # after the job's TAG is set, nothing may read the caller's ref or sha again
        body = text.split("TAG: ${{ inputs.tag || github.ref_name }}", 1)[1]
        self.assertNotIn("github.ref_name", body)
        self.assertNotIn("SHA: ${{ github.sha }}", body)


if __name__ == "__main__":
    unittest.main()
