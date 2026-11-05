"""Real cgroup tests: reparented writers, independent sessions, lost leases and SSH."""
import base64
import errno
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
from unittest import mock
import uuid
from types import SimpleNamespace

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


class StopDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("codex_session", SOURCE)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.unit = "symphony-session-" + "a" * 32 + ".service"
        self.invocation = "b" * 32
        self.props = {"Description": self.unit, "ControlGroup": "/app.slice/" + self.unit,
                      "InvocationID": self.invocation, "LoadState": "loaded", "ActiveState": "failed"}

    def timeout_stop(self, kill=None):
        clock = SimpleNamespace(monotonic=mock.Mock(side_effect=[0, 0, 5]), sleep=mock.Mock())
        with mock.patch.object(self.module, "properties", return_value=self.props), \
                mock.patch.object(self.module, "empty_group", return_value=False), \
                mock.patch.object(self.module, "time", clock), \
                mock.patch.object(self.module.subprocess, "run", side_effect=kill if isinstance(kill, Exception) else None,
                                  return_value=kill or subprocess.CompletedProcess([], 0, b"private-output", b"private-error")), \
                mock.patch.object(self.module.os, "set_blocking", create=True), \
                mock.patch.object(self.module.os, "write") as write:
            result = self.module.stop(self.unit, self.invocation)
        self.assertEqual(result, 3)
        if not isinstance(kill, Exception):
            self.assertEqual(clock.sleep.call_args_list, [mock.call(0.02)])
        write.assert_called_once()
        message = write.call_args.args[1]
        self.assertLessEqual(len(message), 4096)
        self.assertNotIn(b"private", message)
        return json.loads(message.decode().removeprefix("SYMPHONY_SESSION_STOP "))

    def test_populated_timeout_reports_failure_without_exposing_command_output(self):
        diagnostic = self.timeout_stop()
        self.assertEqual(diagnostic["reason"], "cgroup_populated_timeout")
        self.assertEqual(diagnostic["unit"], self.unit)
        self.assertEqual(diagnostic["invocation"], self.invocation)
        self.assertEqual(diagnostic["cgroup"], self.props["ControlGroup"])
        self.assertEqual(diagnostic["kill"], {"returncode": 0})

    def test_kill_failure_is_retained_when_population_does_not_clear(self):
        diagnostic = self.timeout_stop(subprocess.CompletedProcess([], 1, b"private-output", b"private-error"))
        self.assertEqual(diagnostic["kill"], {"returncode": 1})

    def test_kill_timeout_reports_outcome_without_command_or_stderr(self):
        diagnostic = self.timeout_stop(subprocess.TimeoutExpired("private-command", 5, b"private-output", b"private-error"))
        self.assertEqual(diagnostic["reason"], "kill_timeout")
        self.assertEqual(diagnostic["kill"], {"outcome": "timeout"})

    @staticmethod
    def stat(pid, start=123456, state="D"):
        fields = [state, "1"] + ["0"] * 17 + [str(start)]
        return f"{pid} (private process name) " + " ".join(fields)

    def test_timeout_samples_bounded_pids_and_only_nonsecret_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            group = self.props["ControlGroup"]
            cgroup = root / "sys/fs/cgroup" / group.lstrip("/")
            cgroup.mkdir(parents=True)
            (cgroup / "cgroup.events").write_text("populated 1\nfrozen 0\nprivate-secret 1\n")
            (cgroup / "cgroup.procs").write_text("\n".join(str(pid) for pid in range(100, 110)))
            for pid in range(100, 108):
                proc = root / "proc" / str(pid)
                proc.mkdir(parents=True)
                (proc / "stat").write_text(self.stat(pid))
                (proc / "cgroup").write_text("0::" + group + "\n")
                (proc / "wchan").write_text("io_schedule\n")
            with mock.patch.object(self.module, "Path", side_effect=lambda path: root / str(path).lstrip("/")):
                with mock.patch.object(self.module, "properties", return_value=self.props):
                    snapshot = self.module.stop_snapshot(self.unit, self.props)
            with mock.patch.object(self.module, "stop_snapshot", return_value=snapshot):
                diagnostic = self.timeout_stop()
        self.assertEqual(diagnostic["snapshot"], "sampled")
        self.assertEqual(diagnostic["cgroup_events"], {"populated": 1, "frozen": 0})
        self.assertTrue(diagnostic["pids_truncated"])
        self.assertEqual(len(diagnostic["pids"]), 8)
        self.assertEqual(diagnostic["pids"][0], {"pid": 100, "state": "D", "ppid": 1,
                                               "starttime": 123456, "wchan": "io_schedule"})
        self.assertEqual(diagnostic["pid_scope"], "direct_cgroup_only")
        self.assertEqual(diagnostic["descendants"], "unknown")

    def test_nested_population_is_not_reported_as_an_empty_session(self):
        with mock.patch.object(self.module, "properties", return_value=self.props), \
                mock.patch.object(self.module, "read_limited", side_effect=["populated 1\nfrozen 0\n", ""]):
            diagnostic = self.module.stop_snapshot(self.unit, self.props)
        self.assertEqual(diagnostic["cgroup_events"]["populated"], 1)
        self.assertEqual(diagnostic["pids"], [])
        self.assertEqual(diagnostic["pid_scope"], "direct_cgroup_only")
        self.assertEqual(diagnostic["descendants"], "unknown")

    def test_process_races_and_missing_data_are_unknown(self):
        group = self.props["ControlGroup"]
        cases = [FileNotFoundError("private-path"), PermissionError("private-path"),
                 [self.stat(100), "0::" + group, "io_schedule", self.stat(100, start=999), "0::" + group],
                 [self.stat(100), "0::" + group, "io_schedule", self.stat(100), "0::/other-session"]]
        for reads in cases:
            with self.subTest(reads=type(reads).__name__), \
                    mock.patch.object(self.module, "read_limited", side_effect=reads) as read:
                result = self.module.process_snapshot(100, group)
            self.assertEqual(result["state"], "unknown")
            self.assertNotIn("wchan", result)
            self.assertTrue(all(call.args[0].name in ("stat", "cgroup", "wchan") for call in read.call_args_list))

    def test_unit_reuse_prevents_process_inspection(self):
        for change in ({"InvocationID": "c" * 32}, {"ControlGroup": "/other/" + self.unit}):
            with self.subTest(change=change), \
                    mock.patch.object(self.module, "properties", return_value=self.props | change), \
                    mock.patch.object(self.module, "read_limited") as read:
                result = self.module.stop_snapshot(self.unit, self.props)
            self.assertEqual(result, {"snapshot": "unknown", "snapshot_reason": "identity_changed"})
            read.assert_not_called()

    def test_slow_snapshot_does_not_extend_stop_indefinitely(self):
        release = threading.Event()
        def slow_snapshot(*_):
            release.wait(2)
            return {"snapshot": "sampled"}
        started = time.monotonic()
        try:
            with mock.patch.object(self.module, "stop_snapshot", side_effect=slow_snapshot):
                diagnostic = self.timeout_stop()
            self.assertLess(time.monotonic() - started, 1)
            self.assertEqual(diagnostic["snapshot_reason"], "timeout")
        finally:
            release.set()

    def test_snapshot_resource_failure_and_oversized_payload_keep_bounded_failure(self):
        with mock.patch.object(self.module.threading.Thread, "start", side_effect=RuntimeError("private-error")):
            self.assertEqual(self.timeout_stop()["snapshot_reason"], "unavailable")
        with mock.patch.object(self.module, "stop_snapshot", return_value={"oversized": "private" * 1000}):
            diagnostic = self.timeout_stop()
            self.assertEqual(diagnostic["snapshot_reason"], "size_limit")
            self.assertEqual(diagnostic["unit"], self.unit)

    def test_full_error_pipe_does_not_block_or_change_failure_result(self):
        with mock.patch.object(self.module.os, "set_blocking", create=True), \
                mock.patch.object(self.module.os, "write", side_effect=BlockingIOError):
            self.assertEqual(self.module.stop_failure(self.unit, "unit_query_failed"), 3)

    def test_invalid_identity_is_not_included_in_diagnostic(self):
        for change in ({"InvocationID": "private-invalid"},
                       {"ControlGroup": "/private/../" + self.unit},
                       {"ControlGroup": "/" + "a" * 1024 + "/" + self.unit}):
            with self.subTest(change=next(iter(change))), \
                    mock.patch.object(self.module.os, "set_blocking", create=True), \
                    mock.patch.object(self.module.os, "write") as write:
                self.assertEqual(self.module.stop_failure(self.unit, "cgroup_populated_timeout",
                                                         self.props | change), 3)
            message = write.call_args.args[1]
            diagnostic = json.loads(message.decode().removeprefix("SYMPHONY_SESSION_STOP "))
            self.assertEqual(diagnostic["identity"], "unknown")
            self.assertNotIn("invocation", diagnostic)
            self.assertNotIn("cgroup", diagnostic)
            self.assertNotIn(b"private", message)

    def test_successful_stop_keeps_silent_confirmation(self):
        with mock.patch.object(self.module, "properties", return_value=self.props), \
                mock.patch.object(self.module, "empty_group", return_value=True), \
                mock.patch.object(self.module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                mock.patch.object(self.module.os, "write") as write:
            self.assertEqual(self.module.stop(self.unit, self.invocation), 0)
        write.assert_not_called()

    def test_removed_cgroup_read_race_requires_a_fresh_missing_confirmation(self):
        clock = SimpleNamespace(monotonic=mock.Mock(side_effect=[0, 0, 0.02]), sleep=mock.Mock())
        with mock.patch.object(self.module, "properties", return_value=self.props), \
                mock.patch.object(self.module.Path, "read_text", side_effect=[
                    OSError(errno.ENODEV, "private-path"), FileNotFoundError("private-path")]) as read, \
                mock.patch.object(self.module, "time", clock), \
                mock.patch.object(self.module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                mock.patch.object(self.module.os, "set_blocking", create=True), \
                mock.patch.object(self.module.os, "write") as write:
            self.assertEqual(self.module.stop(self.unit, self.invocation), 0)
        self.assertEqual(read.call_count, 2)
        self.assertEqual(clock.sleep.call_args_list, [mock.call(0.02)])
        write.assert_not_called()

    def test_unconfirmed_or_unreadable_cgroup_still_fails_closed_with_safe_errno(self):
        for number in (errno.ENODEV, errno.EACCES, errno.EIO):
            clock = SimpleNamespace(monotonic=mock.Mock(side_effect=[0, 0, 1, 5]), sleep=mock.Mock())
            with self.subTest(errno=number), \
                    mock.patch.object(self.module, "properties", return_value=self.props), \
                    mock.patch.object(self.module.Path, "read_text", side_effect=OSError(number, "private-path")) as read, \
                    mock.patch.object(self.module, "time", clock), \
                    mock.patch.object(self.module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                    mock.patch.object(self.module.os, "set_blocking", create=True), \
                    mock.patch.object(self.module.os, "write") as write:
                self.assertEqual(self.module.stop(self.unit, self.invocation), 3)
            message = write.call_args.args[1]
            diagnostic = json.loads(message.decode().removeprefix("SYMPHONY_SESSION_STOP "))
            self.assertEqual(diagnostic["reason"], "cgroup_query_failed")
            self.assertEqual(diagnostic["errno"], number)
            self.assertNotIn(b"private", message)
            self.assertEqual(read.call_count, 2 if number == errno.ENODEV else 1)

    def test_removed_descriptor_followed_by_live_population_is_not_success(self):
        clock = SimpleNamespace(monotonic=mock.Mock(side_effect=[0, 0, 1, 5]), sleep=mock.Mock())
        with mock.patch.object(self.module, "properties", return_value=self.props), \
                mock.patch.object(self.module.Path, "read_text", side_effect=[
                    OSError(errno.ENODEV, "private-path"), "populated 1\n"]), \
                mock.patch.object(self.module, "time", clock), \
                mock.patch.object(self.module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                mock.patch.object(self.module.os, "set_blocking", create=True), \
                mock.patch.object(self.module.os, "write") as write:
            self.assertEqual(self.module.stop(self.unit, self.invocation), 3)
        diagnostic = json.loads(write.call_args.args[1].decode().removeprefix("SYMPHONY_SESSION_STOP "))
        self.assertEqual(diagnostic["reason"], "cgroup_populated_timeout")
        self.assertNotIn("errno", diagnostic)


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
