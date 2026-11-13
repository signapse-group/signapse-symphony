from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import selectors
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
QA = os.environ.get('SYMPHONY_BROWSER_TEST_QA')
MODULES = os.environ.get('SYMPHONY_BROWSER_TEST_NODE_MODULES')
PRELOAD = ROOT / 'ops/grouped/playwright-browser-lease.cjs'


@unittest.skipUnless(QA and MODULES and shutil.which('node'),
                     'requires pinned QA source, Playwright 1.63.0 and Chromium')
class GroupedBrowserMcpTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.workspace = Path(temp.name).resolve()
        self.modules = Path(MODULES).resolve()
        (self.workspace / 'node_modules').symlink_to(self.modules, target_is_directory=True)
        self.helper = Path(QA).resolve() / 'scripts/runtime/browser_lease.py'
        self.lock = self.workspace / 'signapse-ui-integration.lock'
        self.lock.touch()
        state = self.workspace / 'browser-lease'
        state.mkdir(mode=0o700)
        self.owner = state / (self.lock.name + '.owner.json')
        self.group = '/user.slice/symphony-session-' + '1' * 32 + '.service'
        self.events = self.workspace / 'cgroups' / self.group.lstrip('/') / 'cgroup.events'
        self.events.parent.mkdir(parents=True)
        self.events.write_text('populated 1\n')
        self.hold = self.workspace / 'hold.py'
        self.hold.write_text(
            'from pathlib import Path\n'
            'import sys\n'
            f'sys.path.insert(0, {str(self.helper.parent)!r})\n'
            'import browser_lease as lease\n'
            f'lease.CGROUP_ROOT = Path({str(self.workspace / "cgroups")!r})\n'
            f'lease.session_group = lambda: {self.group!r}\n'
            'try:\n'
            '    raise SystemExit(lease.main(sys.argv[1:]))\n'
            'except lease.ResourceBusy:\n'
            '    raise SystemExit(lease.BUSY_EXIT)\n'
        )
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            self.port = listener.getsockname()[1]
        self.server_started = self.workspace / 'webserver-started'
        (self.workspace / 'web.cjs').write_text(
            "const fs = require('node:fs');\n"
            f"require('node:http').createServer((_, res) => res.end('<h1>Fixture</h1>')).listen({self.port}, "
            f"'127.0.0.1', () => fs.writeFileSync({json.dumps(str(self.server_started))}, 'started'));\n"
        )
        config = {
            'testDir': '.',
            'projects': [{'name': 'chromium'}],
            'webServer': {'command': 'node web.cjs', 'url': f'http://127.0.0.1:{self.port}'},
        }
        (self.workspace / 'playwright.agents.config.cjs').write_text('module.exports = ' + json.dumps(config))
        (self.workspace / 'seed.spec.cjs').write_text(
            "const {test, expect} = require('@playwright/test');\n"
            f"test('fixture', async ({{page}}) => {{ await page.goto('http://127.0.0.1:{self.port}'); "
            "await expect(page.getByRole('heading')).toHaveText('Fixture'); });\n"
        )

    @contextmanager
    def mcp(self):
        env = os.environ | {'SYMPHONY_BROWSER_LEASE': str(self.hold), 'SYMPHONY_BROWSER_LOCK': str(self.lock)}
        command = ['node', '--require', str(PRELOAD), str(self.modules / 'playwright/cli.js'),
                   'run-test-mcp-server', '--headless', '--config', str(self.workspace / 'playwright.agents.config.cjs')]
        with subprocess.Popen(command, cwd=self.workspace, env=env, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            try:
                result = self.rpc(process, 1, 'initialize', {
                    'protocolVersion': '2024-11-05', 'capabilities': {}, 'clientInfo': {'name': 'fixture', 'version': '1'},
                })
                self.assertIn('serverInfo', result)
                self.send(process, {'jsonrpc': '2.0', 'method': 'notifications/initialized'})
                yield process
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

    def send(self, process, message):
        process.stdin.write(json.dumps(message).encode() + b'\n')
        process.stdin.flush()

    def rpc(self, process, identity, method, params):
        self.send(process, {'jsonrpc': '2.0', 'id': identity, 'method': method, 'params': params})
        deadline = time.monotonic() + 25
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                if not selector.select(max(0, deadline - time.monotonic())):
                    break
                line = process.stdout.readline()
                if not line:
                    self.fail('Playwright MCP exited: ' + process.stderr.read().decode())
                message = json.loads(line)
                if message.get('id') == identity:
                    self.assertNotIn('error', message)
                    return message['result']
        self.fail(f'Playwright MCP timed out: {method}')

    def tool(self, process, identity, name, arguments):
        return self.rpc(process, identity, 'tools/call', {'name': name, 'arguments': arguments})

    def cli_probe(self):
        return subprocess.run([sys.executable, str(self.helper), 'run', str(self.lock), '/bin/true'],
                              capture_output=True, text=True, timeout=6)

    def setup_planner(self, process, identity):
        return self.tool(process, identity, 'planner_setup_page', {'project': 'chromium', 'seedFile': 'seed.spec.cjs'})

    def test_planner_acquires_before_webserver_and_releases_after_browser_close(self):
        with self.lock.open('rb') as occupied:
            fcntl.flock(occupied, fcntl.LOCK_EX)
            with self.mcp() as process:
                denied = self.setup_planner(process, 2)
                self.assertTrue(denied['isError'])
                self.assertIn('resource_busy', denied['content'][0]['text'])
                self.assertFalse(self.server_started.exists())
                fcntl.flock(occupied, fcntl.LOCK_UN)
                paused = self.setup_planner(process, 3)
                self.assertFalse(paused.get('isError'), paused)
                self.assertTrue(self.server_started.exists())
                self.assertTrue(self.owner.exists())
                self.assertEqual(self.cli_probe().returncode, 73)
                with self.mcp() as idle:
                    denied = self.setup_planner(idle, 2)
                    self.assertTrue(denied['isError'])
                    self.assertIn('resource_busy', denied['content'][0]['text'])
                closed = self.tool(process, 4, 'browser_close', {'intent': 'close fixture'})
                self.assertFalse(closed.get('isError'), closed)
                self.assertFalse(self.owner.exists())
                with socket.socket() as connection:
                    self.assertNotEqual(connection.connect_ex(('127.0.0.1', self.port)), 0)
                self.assertEqual(self.cli_probe().returncode, 0)

    def test_dead_lease_holder_keeps_fence_until_session_drains(self):
        command = [sys.executable, str(self.hold), 'hold', str(self.lock)]
        with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as holder:
            self.assertEqual(holder.stdout.readline(), b'ready\n')
            holder.kill()
            holder.wait(timeout=5)
            self.assertTrue(self.owner.exists())
            denied = subprocess.run(command, capture_output=True, timeout=5)
            self.assertEqual(denied.returncode, 73)
            self.events.write_text('populated 0\n')
            cleared = subprocess.run(command, input=b'release\n', capture_output=True, timeout=5)
            self.assertEqual(cleared.returncode, 0)
            self.assertFalse(self.owner.exists())
