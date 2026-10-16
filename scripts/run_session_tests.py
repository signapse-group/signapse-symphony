"""Run the requested checks with a disposable loopback SSH worker."""
import os
from pathlib import Path
import pwd
import shutil
import socket
import subprocess
import sys
import tempfile
import time


def main():
    with tempfile.TemporaryDirectory(prefix="symphony-session-ssh-") as directory:
        root = Path(directory)
        user = pwd.getpwuid(os.getuid()).pw_name
        for name in ("client", "host"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        (root / "authorized_keys").write_text((root / "client.pub").read_text())
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        runtime = "/run/user/" + str(os.getuid())
        config = root / "sshd_config"
        config.write_text(
            f"Port {port}\nListenAddress 127.0.0.1\nHostKey {root / 'host'}\n"
            f"PidFile {root / 'sshd.pid'}\nAuthorizedKeysFile {root / 'authorized_keys'}\n"
            f"AllowUsers {user}\nStrictModes no\nPasswordAuthentication no\n"
            "KbdInteractiveAuthentication no\nUsePAM no\nPermitRootLogin prohibit-password\n"
            f"SetEnv XDG_RUNTIME_DIR={runtime} DBUS_SESSION_BUS_ADDRESS=unix:path={runtime}/bus\n"
            "LogLevel ERROR\n"
        )
        ssh_config = root / "ssh_config"
        ssh_config.write_text(
            f"Host 127.0.0.1\n  User {user}\n  Port {port}\n  IdentityFile {root / 'client'}\n"
            f"  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n  UserKnownHostsFile {root / 'known_hosts'}\n"
            "  BatchMode yes\n  LogLevel ERROR\n"
        )
        sshd = shutil.which("sshd") or "/usr/sbin/sshd"
        prefix = [] if os.geteuid() == 0 else ["sudo", "-n"]
        process = subprocess.Popen(prefix + [sshd, "-D", "-e", "-f", str(config)])
        try:
            deadline = time.monotonic() + 10
            while True:
                check = subprocess.run(["ssh", "-F", str(ssh_config), "127.0.0.1", "true"], capture_output=True)
                if check.returncode == 0:
                    break
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Disposable SSH worker did not become ready: " + check.stderr.decode())
                time.sleep(0.1)
            env = os.environ.copy()
            env["SYMPHONY_TEST_SSH_HOST"] = f"127.0.0.1:{port}"
            env["SYMPHONY_SSH_CONFIG"] = str(ssh_config)
            return subprocess.call(sys.argv[1:], env=env)
        finally:
            pidfile = root / "sshd.pid"
            if pidfile.exists():
                pid = pidfile.read_text().strip()
                args = Path(f"/proc/{pid}/cmdline").read_bytes()
                if str(config).encode() in args:
                    subprocess.run(prefix + ["kill", "-TERM", pid], check=False)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
