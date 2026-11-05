"""A leased main process lets systemd reap every tool when the session owner disappears."""
import errno
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time

LEASE_SECONDS = 60
UNIT_PATTERN = r"symphony-session-[0-9a-f]{32}\.service"


def exit_guard(code, message):
    # A full logging pipe must never prevent reaping the session.
    try:
        os.set_blocking(2, False)
        os.write(2, (message + "\n").encode())
    except OSError:
        pass
    os._exit(code)


def properties(unit, timeout=5):
    result = subprocess.run(
        ["systemctl", "--user", "show", unit,
         "--property=LoadState,ActiveState,SubState,Result,ControlGroup,InvocationID,Description"],
        capture_output=True, text=True, timeout=timeout, check=False,
    )
    props = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    if result.returncode and props.get("LoadState") != "not-found":
        raise RuntimeError("Unable to query session unit")
    return props


def identity(unit, props):
    return (props.get("Description") == unit
            and props.get("ControlGroup", "").endswith("/" + unit))


def empty_group(group):
    if not group or not group.startswith("/") or ".." in group.split("/"):
        return False
    try:
        return "populated 0" in (Path("/sys/fs/cgroup" + group) / "cgroup.events").read_text().splitlines()
    except FileNotFoundError:
        return True


def read_limited(path, size):
    with path.open(encoding="utf-8") as stream:
        return stream.read(size)


def process_snapshot(pid, group):
    root = Path(f"/proc/{pid}")
    try:
        before = read_limited(root / "stat", 2048).rpartition(")")[2].split()
        member = read_limited(root / "cgroup", 2048).strip() == "0::" + group
        wchan = read_limited(root / "wchan", 128).strip()
        after = read_limited(root / "stat", 2048).rpartition(")")[2].split()
        member = member and read_limited(root / "cgroup", 2048).strip() == "0::" + group
        if not member or before[19] != after[19]:
            return {"pid": pid, "state": "unknown", "reason": "identity_changed"}
        if len(after[0]) != 1 or after[0] not in "RSDZTtXxKWPI" or not after[1].isdigit() or not after[19].isdigit():
            raise ValueError("Invalid process stat")
        return {"pid": pid, "state": after[0], "ppid": int(after[1]), "starttime": int(after[19]),
                "wchan": wchan if re.fullmatch(r"[A-Za-z0-9_]{1,64}", wchan) else "unknown"}
    except (OSError, ValueError, IndexError):
        return {"pid": pid, "state": "unknown", "reason": "unavailable"}


def stop_snapshot(unit, props):
    current = properties(unit, timeout=0.1)
    group = props.get("ControlGroup", "")
    if (len(group) > 1024 or not group.startswith("/") or ".." in group.split("/")
            or any(ord(char) < 32 for char in group)
            or not re.fullmatch(r"[0-9a-f]{32}", props.get("InvocationID", "")) or not identity(unit, current)
            or current.get("InvocationID") != props.get("InvocationID")
            or current.get("ControlGroup") != group):
        return {"snapshot": "unknown", "snapshot_reason": "identity_changed"}
    root = Path("/sys/fs/cgroup" + group)
    events = {}
    for line in read_limited(root / "cgroup.events", 128).splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] in ("populated", "frozen") and parts[1] in ("0", "1"):
            events[parts[0]] = int(parts[1])
    raw_pids = read_limited(root / "cgroup.procs", 1024)
    pids = [int(value) for value in raw_pids.split()[:8] if re.fullmatch(r"[1-9][0-9]{0,9}", value)]
    return {"snapshot": "sampled", "unit_state": unit_state(current), "cgroup_events": events,
            "pids": [process_snapshot(pid, group) for pid in pids],
            "pid_scope": "direct_cgroup_only", "descendants": "unknown",
            "pids_truncated": len(raw_pids.split()) > 8 or len(raw_pids) == 1024}


def unit_state(props):
    return {key: value if re.fullmatch(r"[a-z-]{1,32}", value) else "unknown"
            for key in ("LoadState", "ActiveState", "SubState", "Result")
            for value in [props.get(key, "unknown")]}


def stop_failure(unit, reason, props=None, kill=None, error_number=None):
    diagnostic = {"unit": unit, "reason": reason}
    if isinstance(error_number, int):
        diagnostic["errno"] = error_number
    if kill is not None:
        diagnostic["kill"] = kill
    if props is not None:
        diagnostic["unit_state"] = unit_state(props)
        group = props.get("ControlGroup", "")
        invocation = props.get("InvocationID", "")
        if (identity(unit, props) and re.fullmatch(r"[0-9a-f]{32}", invocation)
                and len(group) <= 1024 and group.startswith("/") and ".." not in group.split("/")
                and not any(ord(char) < 32 for char in group)):
            diagnostic.update(invocation=invocation, cgroup=group)
        else:
            diagnostic["identity"] = "unknown"
        snapshot = []

        def collect():
            try:
                snapshot.append(stop_snapshot(unit, props))
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                snapshot.append({"snapshot": "unknown", "snapshot_reason": "unavailable"})

        # Diagnostics must not extend a failed stop indefinitely on a blocked procfs read.
        try:
            worker = threading.Thread(target=collect, daemon=True)
            worker.start()
            worker.join(0.2)
        except RuntimeError:
            snapshot.append({"snapshot": "unknown", "snapshot_reason": "unavailable"})
        diagnostic.update(snapshot[0] if snapshot else {"snapshot": "unknown", "snapshot_reason": "timeout"})
    message = ("SYMPHONY_SESSION_STOP " + json.dumps(diagnostic, separators=(",", ":")) + "\n").encode()
    if len(message) > 4096:
        diagnostic = {"unit": unit if re.fullmatch(UNIT_PATTERN, unit) else "unknown", "reason": reason,
                      "snapshot": "unknown", "snapshot_reason": "size_limit"}
        if isinstance(error_number, int):
            diagnostic["errno"] = error_number
        message = ("SYMPHONY_SESSION_STOP " + json.dumps(diagnostic, separators=(",", ":")) + "\n").encode()
    try:
        os.set_blocking(2, False)
        os.write(2, message)
    except OSError:
        pass
    return 3


def stop(unit, invocation):
    try:
        props = properties(unit)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return stop_failure(unit, "unit_query_failed")
    if props.get("LoadState") == "not-found":
        return 0 if invocation else stop_failure(unit, "unverified_missing_unit")
    if invocation and props.get("InvocationID") != invocation:
        return stop_failure(unit, "invocation_mismatch")
    group = props.get("ControlGroup", "")
    if not identity(unit, props):
        return (0 if invocation and props.get("InvocationID") == invocation
                and props.get("ActiveState") in ("inactive", "failed") and not group
                else stop_failure(unit, "unit_identity_unverified"))
    try:
        result = subprocess.run(
            ["systemctl", "--user", "kill", "--signal=SIGKILL", "--kill-whom=all", unit],
            capture_output=True, timeout=5, check=False,
        )
        kill = {"returncode": result.returncode}
    except subprocess.TimeoutExpired:
        return stop_failure(unit, "kill_timeout", props, {"outcome": "timeout"})
    except (OSError, subprocess.SubprocessError):
        return stop_failure(unit, "kill_failed", props, {"outcome": "unavailable"})
    deadline = time.monotonic() + 5
    last_errno = None
    while time.monotonic() < deadline:
        try:
            if empty_group(group):
                return 0
            last_errno = None
        except OSError as error:
            if error.errno != errno.ENODEV:
                return stop_failure(unit, "cgroup_query_failed", props, kill, error.errno)
            # Removing a cgroup between open and read invalidates its kernfs descriptor.
            last_errno = error.errno
        time.sleep(0.02)
    if last_errno is not None:
        return stop_failure(unit, "cgroup_query_failed", props, kill, last_errno)
    return stop_failure(unit, "cgroup_populated_timeout", props, kill)


def launch(source, unit, command, workspace):
    names = sorted(name for name in os.environ if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name)
                   and name not in {"INVOCATION_ID", "SYSTEMD_EXEC_PID", "JOURNAL_STREAM", "NOTIFY_SOCKET"})
    args = ["systemd-run", "--user", "--quiet", "--pipe", "--wait", "--collect",
            "--expand-environment=no", "--service-type=exec", "--unit=" + unit,
            "--description=" + unit, "--property=KillMode=control-group",
            "--property=TimeoutStopSec=1s", "--property=SendSIGKILL=yes"]
    group = Path("/proc/self/cgroup").read_text().strip().removeprefix("0::")
    owner = group.rsplit("/", 1)[-1]
    if owner.endswith(".service") and not owner.startswith("user@"):
        props = properties(owner)
        if props.get("ControlGroup") == group and props.get("ActiveState") == "active":
            args += ["--property=BindsTo=" + owner, "--property=After=" + owner]
    # Copy the filtered caller environment by name so secret values never enter argv.
    args += ["--setenv=" + name for name in names]
    args += [sys.executable, "-u", "-c", "import base64,sys;exec(base64.b64decode(sys.argv[1]))",
             source, "guard", unit, command, workspace, json.dumps(names)]
    os.execvp(args[0], args)


def guard(unit, command, workspace, names):
    environment = {name: os.environ[name] for name in names if name in os.environ}
    props = properties(unit)
    group = Path("/proc/self/cgroup").read_text().strip().removeprefix("0::")
    if not identity(unit, props) or props["ControlGroup"] != group or not props.get("InvocationID"):
        return 3
    child = None
    last_heartbeat = time.monotonic()

    def watch():
        while True:
            age = time.monotonic() - last_heartbeat
            if age > LEASE_SECONDS:
                exit_guard(75, f"SYMPHONY_SESSION_EXIT reason=heartbeat_expired unit={unit} heartbeat_age_seconds={age:.3f}")
            if child is not None and child.poll() is not None:
                exit_guard(0 if child.returncode == 0 else 3,
                           f"SYMPHONY_SESSION_EXIT reason=child_exit unit={unit} child_exit_code={child.returncode}")
            time.sleep(0.1)

    threading.Thread(target=watch, daemon=True).start()
    print("SYMPHONY_CGROUP:" + props["InvocationID"], flush=True)
    for line in sys.stdin.buffer:
        if line == b"SYMPHONY_HEARTBEAT\n":
            last_heartbeat = time.monotonic()
        elif line == b"SYMPHONY_START\n" and child is None:
            child = subprocess.Popen(["bash", "-lc", command], cwd=workspace, env=environment,
                                     stdin=subprocess.PIPE)
        elif child is not None:
            child.stdin.write(line)
            child.stdin.flush()
        else:
            return 3
    # systemd kills the whole cgroup after its main process exits, including daemonized tools.
    os.write(2, f"SYMPHONY_SESSION_EXIT reason=stdin_closed unit={unit}\n".encode())
    return 3


def main():
    source, mode, unit, *args = sys.argv[1:]
    if not re.fullmatch(UNIT_PATTERN, unit):
        return 3
    if mode == "stop" and args[0] and not re.fullmatch(r"[0-9a-f]{32}", args[0]):
        return 3
    if mode == "launch":
        return launch(source, unit, *args)
    if mode == "guard":
        return guard(unit, args[0], args[1], json.loads(args[2]))
    if mode == "stop":
        return stop(unit, args[0])
    return 3


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        sys.exit(3)
