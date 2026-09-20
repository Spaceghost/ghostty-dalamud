"""Regression guards for the workflows: what they build, and on which runners.

The fix these guard is small and easy to lose: a pull request's `github.sha` is
the merge result, so that is what CI must check out. Checking out the branch
head tests something GitHub will never merge.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.yml"))


class WorkflowCheckouts(unittest.TestCase):
    def test_there_are_workflows_to_check(self):
        self.assertTrue(WORKFLOWS, "no workflows found; the guard would pass vacuously")

    def test_every_checkout_takes_the_event_commit_and_no_credentials(self):
        for workflow in WORKFLOWS:
            text = workflow.read_text(encoding="utf-8")
            checkouts = re.findall(
                r"(?ms)^\s+- uses: actions/checkout@[^\n]+\n(.*?)(?=^\s+- |\Z)", text)
            with self.subTest(workflow=workflow.name):
                self.assertTrue(checkouts, "a workflow with no checkout step")
                for checkout in checkouts:
                    self.assertRegex(checkout, r"ref: \$\{\{ github\.sha \}\}")
                    self.assertIn("persist-credentials: false", checkout)
                self.assertNotIn("github.event.pull_request.head.sha", text)

    def test_no_workflow_runs_untrusted_code_with_a_write_token(self):
        for workflow in WORKFLOWS:
            with self.subTest(workflow=workflow.name):
                self.assertNotIn("pull_request_target:", workflow.read_text(encoding="utf-8"))


class CandidateWorkflow(unittest.TestCase):
    """The packaged candidate gate (.github/workflows/candidate.yml)."""

    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / ".github/workflows/candidate.yml").read_text(encoding="utf-8")

    def test_master_is_the_branch_it_builds(self):
        branches = re.search(r"(?m)^    branches: \[([^\]\n]+)\]$", self.workflow)
        self.assertIsNotNone(branches, "expected an explicit push branch allowlist")
        self.assertEqual([b.strip() for b in branches.group(1).split(",")], ["master"])

    def test_the_artifact_names_the_tested_commit(self):
        self.assertIn("name: GhosttyDalamud-candidate-${{ github.sha }}", self.workflow)

    def test_a_self_hosted_runner_is_only_ever_chosen_by_hand(self):
        self.assertIn("default: hosted", self.workflow)
        runners = re.findall(r"(?m)^    runs-on: (.+)$", self.workflow)
        self.assertTrue(runners)
        for runner in runners:
            self.assertIn(
                "github.event_name == 'workflow_dispatch' && inputs.runner == 'self-hosted'",
                runner)


if __name__ == "__main__":
    unittest.main()
