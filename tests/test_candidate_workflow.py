"""Regression guards for the candidate workflow's small, explicit YAML layout."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CandidateWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

    def test_default_branch_is_built(self):
        branches = re.search(r"(?m)^    branches: \[([^\]\n]+)\]$", self.workflow)
        self.assertIsNotNone(branches, "Expected the explicit push branch allowlist")
        self.assertIn("master", [b.strip() for b in branches.group(1).split(",")])

    def test_both_jobs_checkout_the_event_commit(self):
        checkouts = re.findall(
            r"(?ms)^      - uses: actions/checkout@[^\n]+\n(.*?)(?=^      - |\Z)",
            self.workflow,
        )
        self.assertEqual(len(checkouts), 2)
        for checkout in checkouts:
            self.assertRegex(checkout, r"(?m)^          ref: \$\{\{ github\.sha \}\}$")
            self.assertIn("persist-credentials: false", checkout)
        self.assertNotIn("github.event.pull_request.head.sha", self.workflow)

    def test_artifact_names_the_tested_commit(self):
        self.assertIn("name: GhosttyDalamud-candidate-${{ github.sha }}", self.workflow)

    def test_untrusted_prs_do_not_select_self_hosted_runners(self):
        self.assertNotIn("pull_request_target:", self.workflow)
        self.assertIn("default: hosted", self.workflow)
        runners = re.findall(r"(?m)^    runs-on: (.+)$", self.workflow)
        self.assertEqual(len(runners), 2)
        for runner in runners:
            self.assertIn("github.event_name == 'workflow_dispatch' && inputs.runner == 'self-hosted'", runner)


if __name__ == "__main__":
    unittest.main()
