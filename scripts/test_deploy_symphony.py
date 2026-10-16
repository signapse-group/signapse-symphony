"""Offline deployment checks: python3 -m unittest discover -s scripts -p 'test_*.py'."""

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
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
        self.config = self.root / 'old-sys.config'
        self.config.write_text('existing origins and application configuration')
        self.sha = 'a' * 40
        self.release = self.root / 'runtime/releases' / self.sha
        self.before = dict.fromkeys(deploy.SERVICES, '/old/symphony')

    def prepare(self):
        with patch.object(deploy, 'properties', return_value={
            'ActiveState': 'active', 'MainPID': '123', 'ExecStart': '/old/symphony'
        }), patch.object(deploy, 'process_environment', return_value={
            'ERL_FLAGS': f'-config {self.config.with_suffix("")} +S 2'
        }):
            return deploy.prepare(self.sha, self.candidate, self.release)

    def test_bad_checksum_never_reaches_systemd(self):
        self.artifact.write_bytes(b'corrupted')
        with patch.object(deploy, 'systemctl') as ctl:
            with self.assertRaisesRegex(ValueError, 'checksum'):
                self.prepare()
            ctl.assert_not_called()
        self.assertFalse(self.release.exists())

    def test_prepare_preserves_per_service_runtime_configuration(self):
        before, configs = self.prepare()
        self.assertEqual(before, self.before)
        self.assertEqual(set(configs), set(deploy.SERVICES))
        for identity, service, repo, port, logs, _ in deploy.WORKERS:
            self.assertEqual((self.release / f'{identity}-sys.config').read_bytes(), self.config.read_bytes())
            env = (self.release / f'{identity}.env').read_text()
            self.assertIn(f'install-{self.sha}/{identity}', env)
            self.assertIn('+S 2', env)
            self.assertIn(f'repos/{repo}/WORKFLOW.md', configs[service].decode())
        self.assertEqual(self.release.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.prepare(), (before, configs))
        self.artifact.write_bytes(b'different binary')
        self.checksum.write_text(f'{hashlib.sha256(self.artifact.read_bytes()).hexdigest()}  {self.artifact.name}')
        with self.assertRaisesRegex(ValueError, 'different binary'):
            self.prepare()

    def test_success_updates_all_four_without_idle_or_pause(self):
        before, configs = self.prepare()
        with patch.object(deploy, 'systemctl') as ctl, patch.object(deploy, 'await_healthy') as healthy:
            deploy.activate(configs, before, self.candidate / 'backup', self.release / 'symphony')
        self.assertEqual(ctl.call_args_list[0].args, ('stop', *deploy.SERVICES))
        self.assertEqual(ctl.call_args_list[-1].args, ('start', *deploy.SERVICES))
        healthy.assert_called_once_with(dict.fromkeys(deploy.SERVICES, str(self.release / 'symphony')))
        for service in deploy.SERVICES:
            self.assertEqual(deploy.dropin(service).read_bytes(), configs[service])

    def test_start_or_health_failure_restores_existing_and_absent_dropins(self):
        for failure in ['start', 'health']:
            with self.subTest(failure=failure):
                before, configs = self.prepare()
                first = deploy.SERVICES[0]
                deploy.atomic_write(deploy.dropin(first), b'previous CD configuration')
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
                self.assertEqual(deploy.dropin(first).read_bytes(), b'previous CD configuration')
                for service in deploy.SERVICES[1:]:
                    self.assertFalse(deploy.dropin(service).exists())

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

    def test_health_reads_http_200_body_and_requires_all_members(self):
        payload = {
            'counts': {'running': 2, 'retrying': 1},
            'runtime_control': {'enabled': True, 'mode': 'running', 'database_error': None,
                                'services': {'qa': {'status': 'online'}}},
        }

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(payload).encode())

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        worker = ('qa', 'qa.service', 'repo', server.server_port, 'logs', {'qa'})
        with patch.object(deploy, 'WORKERS', [worker]), patch.object(deploy, 'properties', return_value={
            'ActiveState': 'active', 'MainPID': '123', 'ExecStart': '/new/symphony'
        }):
            self.assertEqual(deploy.health({'qa.service': '/new/symphony'}), ['123'])
            payload['error'] = {'code': 'snapshot_unavailable'}
            with self.assertRaises(RuntimeError):
                deploy.health({'qa.service': '/new/symphony'})
            del payload['error']
            payload['runtime_control']['services']['qa']['status'] = 'unknown'
            with self.assertRaises(RuntimeError):
                deploy.health({'qa.service': '/new/symphony'})
            payload['runtime_control']['services'] = {}
            with self.assertRaises(RuntimeError):
                deploy.health({'qa.service': '/new/symphony'})

    def test_duplicate_success_event_does_not_restart_services_again(self):
        binary = self.root / 'runtime/releases' / self.sha / 'symphony'
        (self.root / 'runtime').mkdir()
        with patch.object(deploy.sys, 'argv', ['deploy_symphony.py', self.sha, str(self.candidate)]), patch.object(
            deploy, 'prepare', return_value=(dict.fromkeys(deploy.SERVICES, str(binary)), {})
        ), patch.object(deploy, 'await_healthy'), patch.object(deploy, 'activate') as activate:
            deploy.main()
            activate.assert_not_called()


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


if __name__ == '__main__':
    unittest.main()
