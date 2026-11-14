"""Offline deployment checks: python3 -m unittest discover -s scripts -p 'test_*.py'."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import deploy_symphony as deploy


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name, value in [('ROOT', self.root), ('UNITS', self.root / 'units')]:
            mock = patch.object(deploy, name, value)
            mock.start()
            self.addCleanup(mock.stop)
        self.candidate = self.root / 'candidate'
        self.candidate.mkdir()
        self.artifact = self.candidate / 'symphony-nightly-linux_x86_64'
        self.artifact.write_bytes(b'new binary')
        self.checksum = Path(f'{self.artifact}.sha256')
        self.checksum.write_text(f'{hashlib.sha256(self.artifact.read_bytes()).hexdigest()}  {self.artifact.name}\n')
        grouped = self.root / 'runtime/grouped'
        grouped.mkdir(parents=True)
        for name in ['profiles.json', 'service.env', 'sys.config']:
            (grouped / name).touch()
        self.sha = 'a' * 40
        self.release = self.root / 'runtime/releases' / self.sha
        self.before = {deploy.GROUPED_SERVICE: '/old/symphony'}

    def prepare(self):
        with patch.object(deploy, 'properties', return_value={
            'ActiveState': 'active', 'MainPID': '123', 'ExecStart': '/old/symphony'
        }):
            return deploy.prepare_grouped(self.sha, self.candidate, self.release)

    def test_bad_checksum_never_reaches_systemd(self):
        self.artifact.write_bytes(b'corrupted')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.prepare()
        self.assertFalse(self.release.exists())

    def test_prepare_preserves_grouped_manifest_and_runtime_configuration(self):
        before, configs = self.prepare()
        self.assertEqual(before, self.before)
        self.assertEqual(set(configs), {deploy.GROUPED_SERVICE})
        config = configs[deploy.GROUPED_SERVICE].decode()
        self.assertIn(f'install-{self.sha}/grouped', config)
        self.assertIn('runtime/grouped/service.env', config)
        self.assertIn('runtime/grouped/sys', config)
        self.assertIn('--profiles ', config)
        self.assertEqual(self.release.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.prepare(), (before, configs))
        self.artifact.write_bytes(b'different binary')
        self.checksum.write_text(f'{hashlib.sha256(self.artifact.read_bytes()).hexdigest()}  {self.artifact.name}')
        with self.assertRaisesRegex(ValueError, 'different binary'):
            self.prepare()

    def test_success_updates_only_grouped_service(self):
        before, configs = self.prepare()
        with patch.object(deploy, 'systemctl') as ctl, patch.object(deploy, 'await_healthy') as healthy:
            deploy.activate(configs, before, self.candidate / 'backup', self.release / 'symphony')
        self.assertEqual(ctl.call_args_list[0].args, ('stop', deploy.GROUPED_SERVICE))
        self.assertEqual(ctl.call_args_list[-1].args, ('start', deploy.GROUPED_SERVICE))
        healthy.assert_called_once_with({deploy.GROUPED_SERVICE: str(self.release / 'symphony')})
        self.assertEqual(deploy.dropin(deploy.GROUPED_SERVICE).read_bytes(), configs[deploy.GROUPED_SERVICE])

    def test_start_or_health_failure_restores_existing_and_absent_dropins(self):
        for failure in ['start', 'health']:
            with self.subTest(failure=failure):
                before, configs = self.prepare()
                dropin = deploy.dropin(deploy.GROUPED_SERVICE)
                if failure == 'start':
                    deploy.atomic_write(dropin, b'previous CD configuration')
                starts = []

                def ctl(*args):
                    if args[0] == 'start':
                        starts.append(args)
                        if failure == 'start' and len(starts) == 1:
                            raise subprocess.CalledProcessError(1, 'systemctl start')

                checks = [RuntimeError('unhealthy'), None] if failure == 'health' else [None]
                with patch.object(deploy, 'systemctl', side_effect=ctl), patch.object(
                    deploy, 'await_healthy', side_effect=checks
                ) as healthy:
                    with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                        deploy.activate(configs, before, self.candidate / f'backup-{failure}', self.release / 'symphony')
                healthy.assert_called_with(before)
                if failure == 'start':
                    self.assertEqual(dropin.read_bytes(), b'previous CD configuration')
                    dropin.unlink()
                else:
                    self.assertFalse(dropin.exists())

    def test_execstart_ignores_systemd_process_metadata(self):
        with patch.object(deploy, 'systemctl', return_value=(
            'ActiveState=active\nMainPID=123\n'
            'ExecStart={ path=/new/symphony ; argv[]=/new/symphony workflow ; pid=123 ; }'
        )):
            self.assertEqual(deploy.properties('service')['ExecStart'], '/new/symphony')

    def test_failed_rollback_is_reported_for_manual_recovery(self):
        before, configs = self.prepare()
        with patch.object(deploy, 'systemctl'), patch.object(deploy, 'await_healthy', side_effect=[
            RuntimeError('candidate failed'), RuntimeError('previous runtime failed')
        ]):
            with self.assertRaisesRegex(RuntimeError, 'Rollback failed; manual recovery required'):
                deploy.activate(configs, before, self.candidate / 'backup', self.release / 'symphony')

    def test_duplicate_success_event_does_not_restart_services_again(self):
        binary = self.root / 'runtime/releases' / self.sha / 'symphony'
        grouped = self.root / 'runtime/grouped'
        (grouped / 'cutover-complete').touch()
        with patch.object(deploy.sys, 'argv', ['deploy_symphony.py', self.sha, str(self.candidate)]), patch.object(
            deploy, 'prepare_grouped', return_value=({deploy.GROUPED_SERVICE: str(binary)}, {})
        ), patch.object(deploy, 'assert_legacy_stopped'), patch.object(
            deploy, 'await_healthy'
        ), patch.object(deploy, 'activate') as activate:
            deploy.main()
            activate.assert_not_called()

    def test_cd_skips_until_operator_verifies_cutover(self):
        with patch.object(deploy.sys, 'argv', ['deploy_symphony.py', self.sha, str(self.candidate)]), patch.object(
            deploy, 'systemctl'
        ) as ctl:
            deploy.main()
        ctl.assert_not_called()

    def test_initial_prepare_stages_release_without_touching_units(self):
        with patch.object(deploy.sys, 'argv', [
            'deploy_symphony.py', '--prepare-grouped', self.sha, str(self.candidate)
        ]), patch.object(deploy, 'systemctl') as ctl:
            deploy.main()
        ctl.assert_not_called()
        self.assertTrue((self.candidate / 'grouped-90-cd.conf').is_file())
        self.assertTrue((self.release / 'symphony').is_file())
        self.assertFalse(deploy.dropin(deploy.GROUPED_SERVICE).exists())

    def test_grouped_health_requires_all_profiles_and_independent_control(self):
        profiles = [
            {'profile_id': identity, 'health': 'healthy', 'max_concurrent_agents': cap,
             'workflow_revision': 'workflow-sha', 'instructions_revision': 'instructions-sha',
             'runtime_control': {'enabled': True, 'mode': 'paused', 'database_error': None,
                                 'services': {identity: {'status': 'online'}}}}
            for identity, cap in deploy.PROFILES.items()
        ]
        state = {'mode': 'profiles', 'health': 'healthy', 'profiles': profiles}
        with patch.object(deploy, 'properties', return_value={
            'ActiveState': 'active', 'MainPID': '123', 'ExecStart': '/new/symphony'
        }), patch.object(deploy.urllib.request, 'urlopen') as open_url, patch.object(
            deploy.json, 'load', return_value=state
        ):
            self.assertEqual(deploy.health({deploy.GROUPED_SERVICE: '/new/symphony'}), ['123'])
            open_url.assert_called_once_with('http://127.0.0.1:4000/api/v1/state', timeout=5)
            checkout = profiles[0]
            checkout.pop('instructions_revision')
            for source in [None, 'package', 'unknown', 'checkout']:
                with self.subTest(source=source):
                    checkout.update(instructions_source=source)
                    expected = {deploy.GROUPED_SERVICE: '/new/symphony'}
                    if source == 'checkout':
                        self.assertEqual(deploy.health(expected), ['123'])
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'fe:'):
                            deploy.health(expected)
            checkout.pop('workflow_revision')
            with self.assertRaisesRegex(RuntimeError, 'fe:'):
                deploy.health({deploy.GROUPED_SERVICE: '/new/symphony'})
            checkout['workflow_revision'] = 'workflow-sha'
            profiles[1]['runtime_control']['services']['landing'] = {'status': 'online'}
            with self.assertRaisesRegex(RuntimeError, 'be:'):
                deploy.health({deploy.GROUPED_SERVICE: '/new/symphony'})


class WorkflowGateTests(unittest.TestCase):
    def test_gate_handles_either_completion_order_failed_ci_and_superseded_commits(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/deploy.yml').read_text()
        script = workflow.split('        run: |\n', 1)[1].split('\n      - name:', 1)[0]
        script = '\n'.join(line[10:] for line in script.splitlines())
        for ci, build, head, ready in [
            ('success', 'success', 'a', True),
            ('pending', 'success', 'a', False),
            ('success', 'pending', 'a', False),
            ('failure', 'success', 'a', False),
            ('success', 'success', 'b', False),
        ]:
            with self.subTest(ci=ci, build=build, head=head), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                gh = root / 'gh'
                gh.write_text(
                    '#!/usr/bin/env python3\nimport json,os,sys\n'
                    'path=sys.argv[2]\n'
                    'if "/commits/" in path: print(os.environ["HEAD_SHA"])\n'
                    'else:\n'
                    ' result=os.environ["CI_RESULT" if "make-all.yml" in path else "BUILD_RESULT"]\n'
                    ' print(json.dumps({"workflow_runs":[{"status":"in_progress" if result=="pending" else "completed","conclusion":result,"id":42}]}))\n'
                )
                gh.chmod(0o700)
                output = root / 'output'
                output.touch()
                subprocess.run(['bash', '-c', script], check=True, capture_output=True, env={
                    **os.environ, 'PATH': f'{root}:{os.environ["PATH"]}',
                    'GITHUB_REPOSITORY': 'signapse-group/signapse-symphony',
                    'SOURCE_SHA': 'a', 'HEAD_SHA': head, 'CI_RESULT': ci,
                    'BUILD_RESULT': build, 'GITHUB_OUTPUT': str(output),
                })
                self.assertEqual('ready=true' in output.read_text(), ready)

    def test_workflow_rejects_missing_or_wrong_otp_and_mismatched_bytes(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/deploy.yml').read_text()
        step = workflow.split('      - name: Verify production artifact and packaged OTP\n', 1)[1]
        script = step.split('        run: |\n', 1)[1].split('\n      - name:', 1)[0]
        script = '\n'.join(line[10:] for line in script.splitlines())
        for otp, artifact_bytes, expected in [
            (None, b'candidate', False),
            ('28.5.0.6', b'candidate', False),
            ('28.5.0.8', b'wrong artifact', False),
            ('28.5.0.8', b'candidate', True),
        ]:
            with self.subTest(otp=otp, artifact_bytes=artifact_bytes), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                artifact = root / 'symphony-nightly-linux_x86_64'
                artifact.write_bytes(artifact_bytes)
                Path(f'{artifact}.sha256').write_text(f'{hashlib.sha256(b"candidate").hexdigest()}  {artifact.name}\n')
                if otp is not None:
                    Path(f'{artifact}.otp-version').write_text(otp + '\n')
                result = subprocess.run(['bash', '-c', script], cwd=root, capture_output=True)
                self.assertEqual(result.returncode == 0, expected, result.stderr)


if __name__ == '__main__':
    unittest.main()
