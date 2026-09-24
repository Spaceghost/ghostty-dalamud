"""The ghostty-agent container image for the atomic desktops: the Containerfile
builds the RPM from the source tarball with no network, the quadlet runs it as
the user without relabelling their home, and the workflow never pushes unless
asked by hand. Static checks; tools/ci/container-smoke.sh is the live one."""
from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent
PKG = ROOT / 'packaging' / 'container'


def quadlet():
    # quadlet repeats keys (Volume=); keep them all
    sections: dict[str, dict[str, list[str]]] = {}
    current = None
    for line in (PKG / 'ghostty-agent.container').read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        m = re.fullmatch(r'\[(\w+)\]', line)
        if m:
            current = sections.setdefault(m.group(1), {})
            continue
        k, _, v = line.partition('=')
        current.setdefault(k, []).append(v)
    return sections


class Quadlet(unittest.TestCase):
    def test_runs_as_the_user_with_their_home(self):
        c = quadlet()['Container']
        self.assertEqual(c['UserNS'], ['keep-id'])
        self.assertIn('%h:%h', c['Volume'])
        self.assertEqual(c['Environment'], ['HOME=%h'])
        self.assertEqual(c['Network'], ['host'])

    def test_never_relabels_the_home(self):
        c = quadlet()['Container']
        for v in c['Volume']:
            self.assertNotRegex(v, r':[^:]*[zZ]', f'Volume={v} would relabel')
        self.assertEqual(c['SecurityLabelDisable'], ['true'])

    def test_listens_on_loopback_only(self):
        c = quadlet()['Container']
        self.assertEqual(c['Exec'], ['--listen 127.0.0.1:7777'])

    def test_restarts_only_after_a_crash_and_starts_with_the_session(self):
        q = quadlet()
        self.assertEqual(q['Service']['Restart'], ['on-failure'])
        self.assertEqual(q['Install']['WantedBy'], ['default.target'])

    def test_gpu_is_optional(self):
        self.assertEqual(quadlet()['Container']['AddDevice'], ['-/dev/dri'])


class Containerfile(unittest.TestCase):
    text = (PKG / 'Containerfile').read_text()

    def test_rpm_is_built_with_no_network(self):
        run = re.search(r'^RUN --network=none .*?rpmbuild -tb', self.text, re.S | re.M)
        self.assertIsNotNone(run, 'the rpmbuild step must run with --network=none')

    def test_build_stage_has_what_the_spec_build_requires(self):
        spec = (ROOT / 'packaging' / 'ghostty-agent.spec').read_text()
        stage = self.text.split('FROM ${BASE}')[0]
        for pkg in ('rust', 'cargo', 'rpm-build', 'systemd-rpm-macros', 'wlroots-devel', 'binutils'):
            self.assertRegex(stage, rf'\b{re.escape(pkg)}\b', pkg)
        self.assertIn('BuildRequires:  cargo', spec)

    def test_debuginfo_does_not_ship(self):
        self.assertIn("! -name '*debug*'", self.text)

    def test_entrypoint_is_the_agent_on_loopback(self):
        self.assertIn('ENTRYPOINT ["/usr/bin/ghostty-agent"]', self.text)
        self.assertIn('CMD ["--listen", "127.0.0.1:7777"]', self.text)


class Workflow(unittest.TestCase):
    text = (ROOT / '.github' / 'workflows' / 'container.yml').read_text()

    def test_only_by_hand(self):
        on = self.text.split('\non:\n', 1)[1].split('\npermissions:', 1)[0]
        self.assertIn('workflow_dispatch:', on)
        for trigger in ('push:', 'pull_request', 'schedule', 'workflow_run', 'release:'):
            self.assertNotRegex(on, rf'^  {re.escape(trigger)}', trigger)

    def test_push_is_opt_in_and_defaults_off(self):
        self.assertRegex(self.text, r'push:\n\s+description: .*\n\s+type: boolean\n\s+default: false')
        push = self.text.split('- name: Push to ghcr.io', 1)[1]
        self.assertIn('if: inputs.push', push.split('run:', 1)[0])
        self.assertEqual(self.text.count('podman push'), 1)

    def test_smoke_runs_before_anything_is_kept(self):
        steps = self.text.split('\njobs:\n', 1)[1]
        order = [steps.index(s) for s in ('podman build', 'container-smoke.sh', 'upload-artifact', 'podman push')]
        self.assertEqual(order, sorted(order))

    def test_actions_pinned_by_commit(self):
        for use in re.findall(r'uses: (\S+)', self.text):
            self.assertRegex(use, r'@[0-9a-f]{40}$', use)


class Smoke(unittest.TestCase):
    def test_script_parses(self):
        subprocess.run(['bash', '-n', str(ROOT / 'tools' / 'ci' / 'container-smoke.sh')], check=True)

    def test_no_engine_is_127(self):
        r = subprocess.run([shutil.which('bash'), str(ROOT / 'tools' / 'ci' / 'container-smoke.sh')],
                           env={'PATH': '/nonexistent', 'ENGINE': ''}, capture_output=True, text=True)
        self.assertEqual(r.returncode, 127, r.stderr)


if __name__ == '__main__':
    unittest.main()
