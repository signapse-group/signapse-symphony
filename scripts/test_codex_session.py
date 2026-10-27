"""Real cgroup tests: reparented writers, independent sessions, lost leases and SSH."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import selectors
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

SOURCE = Path(__file__).resolve().parents[1] / "elixir/priv/codex_session.py"
ENCODED = base64.b64encode(SOURCE.read_bytes()).decode()
DECODER = "import base64,sys;exec(base64.b64decode(sys.argv[1]))"
FIXTURE = r"""
import json,os,pathlib,sys,time
mode,root=sys.argv[1:]
root=pathlib.Path(root)
if os.fork()==0:
    if mode=='group': os.setpgid(0,0)
    if mode=='daemon':
        os.setsid()
        if os.fork(): os._exit(0)
    (root/'child.pid').write_text(str(os.getpid()))
    while True:
        (root/'heartbeat').write_text(str(time.monotonic_ns()))
        time.sleep(0.02)
while not (root/'heartbeat').exists(): time.sleep(0.01)
(root/'started').write_text(json.dumps({'cwd':os.getcwd(),'sentinel':os.environ.get('SYMPHONY_TEST_SENTINEL')}))
print('READY',flush=True)
for line in sys.stdin: print('ECHO:'+line.strip(),flush=True)
"""


def wait_until(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("condition did not become true")


class Session:
    def __init__(self, root, mode="daemon", remote=False, owner=False, start=True):
        self.root = root
        self.unit = "symphony-session-" + uuid.uuid4().hex + ".service"
        self.invocation = ""
        self.remote = remote
        self.owner = "symphony-test-owner-" + uuid.uuid4().hex + ".service" if owner else None
        fixture = root / "fixture.py"
        fixture.write_text(FIXTURE)
        command = shlex.join([sys.executable, "-u", str(fixture), mode, str(root)])
        args = [sys.executable, "-u", "-c", DECODER, ENCODED, "launch", self.unit, command, str(root)]
        if self.owner:
            args = ["systemd-run", "--user", "--quiet", "--pipe", "--wait", "--collect",
                    "--unit=" + self.owner, "--setenv=SYMPHONY_TEST_SENTINEL"] + args
        env = os.environ.copy()
        env["SYMPHONY_TEST_SENTINEL"] = "literal $value ' quote"
        if remote:
            # Set a harmless sentinel in the remote caller environment.
            args = self.ssh("SYMPHONY_TEST_SENTINEL=" + shlex.quote(env["SYMPHONY_TEST_SENTINEL"]) + " " + shlex.join(args))
        self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env)
        self.beating = threading.Event()
        self.beating.set()
        try:
            line = self.readline()
            assert line.startswith("SYMPHONY_CGROUP:"), (line, self.process.stderr.read().decode())
            self.invocation = line.partition(":")[2]
            if start:
                self.send("SYMPHONY_START")
                assert self.readline() == "READY"
            threading.Thread(target=self.heartbeat, daemon=True).start()
        except BaseException:
            self.close()
            raise

    @staticmethod
    def ssh(command):
        host = os.environ["SYMPHONY_TEST_SSH_HOST"].split(":")[0]
        return ["ssh", "-T", "-F", os.environ["SYMPHONY_SSH_CONFIG"], host, command]

    def readline(self):
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            assert selector.select(10), "session stdout timed out"
            return self.process.stdout.readline().decode().strip()

    def send(self, line):
        self.process.stdin.write((line + "\n").encode())
        self.process.stdin.flush()

    def heartbeat(self):
        while self.beating.wait(0.2) and self.beating.is_set():
            try:
                self.send("SYMPHONY_HEARTBEAT")
            except (OSError, ValueError):
                return
            time.sleep(0.2)

    def inactive(self):
        args = ["systemctl", "--user", "show", self.unit, "--property=LoadState,ActiveState"]
        if self.remote:
            args = self.ssh(shlex.join(args))
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        return any(value in result.stdout for value in
                   ("LoadState=not-found", "ActiveState=inactive", "ActiveState=failed"))

    def stop(self, invocation=None, env=None):
        args = [sys.executable, "-c", DECODER, ENCODED, "stop", self.unit,
                self.invocation if invocation is None else invocation]
        if self.remote:
            args = self.ssh(shlex.join(args))
        return subprocess.run(args, capture_output=True, timeout=20, env=env).returncode

    def assert_quiet(self):
        heartbeat = self.root / "heartbeat"
        value = heartbeat.read_text()
        time.sleep(0.15)
        assert heartbeat.read_text() == value, "old session is still writing"

    def close(self):
        self.beating.clear()
        if self.invocation:
            self.stop()
        if self.process.poll() is None:
            self.process.kill()
        self.process.communicate(timeout=5)


class SessionTests(unittest.TestCase):
    def session(self, **opts):
        directory = tempfile.TemporaryDirectory(prefix="symphony-session-test-")
        self.addCleanup(directory.cleanup)
        session = Session(Path(directory.name), **opts)
        self.addCleanup(session.close)
        return session

    def test_group_sets_and_reparented_tools_are_killed_locally_and_over_ssh(self):
        for remote in (False, True):
            if remote and not os.environ.get("SYMPHONY_TEST_SSH_HOST"):
                continue
            for mode in ("group", "daemon"):
                with self.subTest(remote=remote, mode=mode):
                    session = self.session(mode=mode, remote=remote)
                    session.send('{"literal":"$value and quotes"}')
                    self.assertEqual(session.readline(), 'ECHO:{"literal":"$value and quotes"}')
                    data = json.loads((session.root / "started").read_text())
                    self.assertEqual(data, {"cwd": str(session.root), "sentinel": "literal $value ' quote"})
                    self.assertEqual(session.stop(), 0)
                    session.assert_quiet()
                    self.assertEqual(session.stop(), 0)

    def test_stopping_one_session_does_not_stop_another(self):
        first, second = self.session(), self.session()
        self.assertEqual(first.stop(), 0)
        first.assert_quiet()
        value = (second.root / "heartbeat").read_text()
        wait_until(lambda: (second.root / "heartbeat").read_text() != value)
        self.assertEqual(second.stop(), 0)

    def test_wrong_identity_and_unverified_missing_unit_fail_closed(self):
        session = self.session()
        self.assertNotEqual(session.stop("0" * 32), 0)
        value = (session.root / "heartbeat").read_text()
        wait_until(lambda: (session.root / "heartbeat").read_text() != value)
        self.assertEqual(session.stop(), 0)
        self.assertNotEqual(session.stop(""), 0)

    def test_lost_ssh_connection_reaps_remote_daemon(self):
        if not os.environ.get("SYMPHONY_TEST_SSH_HOST"):
            self.skipTest("run with scripts/run_session_tests.py for a real SSH worker")
        session = self.session(remote=True)
        session.beating.clear()
        session.process.kill()
        session.process.wait(timeout=5)
        wait_until(session.inactive, timeout=70)
        session.assert_quiet()

    def test_expired_lease_reaps_daemon_even_with_open_stdin(self):
        session = self.session()
        session.beating.clear()
        self.assertEqual(session.process.wait(timeout=70), 75)
        self.assertIn(b"reason=heartbeat_expired", session.process.stderr.read())
        session.assert_quiet()

    def test_heartbeat_gap_longer_than_old_lease_keeps_session_alive(self):
        session = self.session()
        session.beating.clear()
        time.sleep(20)
        self.assertIsNone(session.process.poll())
        session.send("SYMPHONY_HEARTBEAT")
        session.send("still-alive")
        self.assertEqual(session.readline(), "ECHO:still-alive")
        self.assertEqual(session.stop(), 0)

    def test_no_agent_starts_before_containment_is_acknowledged(self):
        session = self.session(start=False)
        self.assertFalse((session.root / "started").exists())
        self.assertFalse((session.root / "child.pid").exists())
        self.assertEqual(session.stop(), 0)

    def test_query_or_permission_failure_does_not_confirm_stop(self):
        session = self.session()
        shim = session.root / "systemctl"
        env = os.environ.copy()
        env["PATH"] = str(session.root)
        for command in ("exit 1", "exec /bin/sleep 20"):
            with self.subTest(command=command):
                shim.write_text("#!/bin/sh\n" + command + "\n")
                shim.chmod(0o755)
                self.assertNotEqual(session.stop(env=env), 0)
                value = (session.root / "heartbeat").read_text()
                wait_until(lambda: (session.root / "heartbeat").read_text() != value)

    def test_owner_service_death_reaps_session_and_daemon(self):
        session = self.session(owner=True)
        subprocess.run(["systemctl", "--user", "kill", "--signal=SIGKILL", "--kill-whom=all", session.owner],
                       check=True, capture_output=True)
        session.process.wait(timeout=10)
        session.assert_quiet()


if __name__ == "__main__":
    unittest.main()
