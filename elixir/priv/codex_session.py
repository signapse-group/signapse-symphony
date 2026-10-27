"""A leased main process lets systemd reap every tool when the session owner disappears."""
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


def properties(unit):
    result = subprocess.run(
        ["systemctl", "--user", "show", unit,
         "--property=LoadState,ActiveState,ControlGroup,InvocationID,Description"],
        capture_output=True, text=True, timeout=5, check=False,
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


def stop(unit, invocation):
    props = properties(unit)
    if props.get("LoadState") == "not-found":
        return 0 if invocation else 3
    if invocation and props.get("InvocationID") != invocation:
        return 3
    group = props.get("ControlGroup", "")
    if not identity(unit, props):
        return (0 if invocation and props.get("InvocationID") == invocation
                and props.get("ActiveState") in ("inactive", "failed") and not group else 3)
    subprocess.run(
        ["systemctl", "--user", "kill", "--signal=SIGKILL", "--kill-whom=all", unit],
        capture_output=True, timeout=5, check=False,
    )
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if empty_group(group):
            return 0
        time.sleep(0.02)
    return 3


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
