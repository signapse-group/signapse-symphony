"""Deploy the verified main artifact to the existing four user services."""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.request


ROOT = Path('/opt/apps/symphony')
UNITS = Path.home() / '.config/systemd/user'
WORKERS = (
    ('be', 'symphony.service', 'signapse', 4000, 'logs', {'be', 'fe', 'landing'}),
    ('fe', 'symphony-fe.service', 'signapse-ui', 4001, 'logs-fe', {'be', 'fe', 'landing'}),
    ('landing', 'symphony-landing.service', 'signapse-landing', 4002, 'logs-landing', {'be', 'fe', 'landing'}),
    ('qa', 'symphony-qa.service', 'signapse-qa', 4003, 'logs-qa', {'qa'}),
)
SERVICES = [worker[1] for worker in WORKERS]


def systemctl(*args):
    return subprocess.check_output(
        ['systemctl', '--user', *args], text=True, timeout=90
    ).strip()


def properties(service):
    props = dict(line.split('=', 1) for line in systemctl(
        'show', service, '-p', 'ActiveState', '-p', 'MainPID', '-p', 'ExecStart'
    ).splitlines())
    # systemd includes changing PID/timestamps in ExecStart; compare only its executable.
    props['ExecStart'] = re.search(r'\{ path=(.*?) ;', props['ExecStart'])[1]
    return props


def process_environment(pid):
    return dict(entry.split('=', 1) for entry in
                Path(f'/proc/{pid}/environ').read_bytes().decode().split('\0') if '=' in entry)


def atomic_write(path, data, mode=0o600):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
        try:
            os.fchmod(temporary.fileno(), mode)
            temporary.write(data)
            temporary.flush()
            os.replace(temporary_path, path)
        finally:
            temporary_path.unlink(missing_ok=True)


def dropin(service):
    return UNITS / f'{service}.d/90-cd.conf'


def health(expected):
    pids = []
    for identity, service, _, port, _, members in WORKERS:
        props = properties(service)
        if (props['ActiveState'] != 'active' or props['MainPID'] == '0'
                or props['ExecStart'] != expected[service]):
            raise RuntimeError(f'{service}: process or executable is not ready')
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/v1/state', timeout=5) as response:
            state = json.load(response)
        control = state.get('runtime_control', {})
        services = control.get('services', {})
        if (state.get('error') or not isinstance(state.get('counts'), dict)
                or not control.get('enabled') or control.get('database_error')
                or control.get('mode') not in {'running', 'paused', 'pausing', 'checking_quota'}
                or set(services) != members
                or any(item.get('status') != 'online' for item in services.values())):
            raise RuntimeError(f'{identity}: runtime snapshot or heartbeat is not healthy')
        pids.append(props['MainPID'])
    return pids


def await_healthy(expected):
    deadline = time.monotonic() + 120
    previous, stable = None, 0
    while time.monotonic() < deadline:
        try:
            pids = health(expected)
            stable = stable + 1 if pids == previous else 1
            previous = pids
            if stable >= 3:
                return
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
            previous, stable = None, 0
        time.sleep(1)
    raise RuntimeError('Services did not become healthy within 120 seconds')


def prepare(sha, candidate, release):
    artifact = candidate / 'symphony-nightly-linux_x86_64'
    checksum = Path(f'{artifact}.sha256').read_text().split()
    if (len(checksum) != 2 or not re.fullmatch(r'[0-9a-f]{64}', checksum[0])
            or checksum[1] != artifact.name
            or hashlib.sha256(artifact.read_bytes()).hexdigest() != checksum[0]):
        raise ValueError('Artifact checksum does not match')
    release.mkdir(mode=0o700, parents=True, exist_ok=True)
    binary = release / 'symphony'
    if binary.exists():
        if hashlib.sha256(binary.read_bytes()).hexdigest() != checksum[0]:
            raise ValueError('Release already exists with a different binary')
    else:
        atomic_write(binary, artifact.read_bytes(), 0o700)

    before, configs = {}, {}
    for identity, service, repo, port, logs, _ in WORKERS:
        props = properties(service)
        if props['ActiveState'] != 'active' or props['MainPID'] == '0':
            raise RuntimeError(f'{service} must be running before deployment')
        before[service] = props['ExecStart']
        env = process_environment(props['MainPID'])
        flags = shlex.split(env.get('ERL_FLAGS', ''))
        if flags.count('-config') != 1:
            raise ValueError(f'{service}: expected one existing ERL_FLAGS -config')
        index = flags.index('-config') + 1
        config = Path(flags[index])
        if config.suffix != '.config':
            config = Path(f'{config}.config')
        config_bytes = config.read_bytes()
        config_base = release / f'{identity}-sys'
        flags[index] = str(config_base)
        install = ROOT / f'runtime/install-{sha}/{identity}'
        install.mkdir(mode=0o700, parents=True, exist_ok=True)
        env_path = release / f'{identity}.env'
        # EnvironmentFile has its own quoting rules; preserve the existing Erlang arguments.
        erl_flags = shlex.join(flags).replace('\\', '\\\\').replace('"', '\\"')
        env_bytes = f'SYMPHONY_INSTALL_DIR={install}\nERL_FLAGS="{erl_flags}"\n'.encode()
        config_path = Path(f'{config_base}.config')
        for path, data in [(config_path, config_bytes), (env_path, env_bytes)]:
            if path.exists() and path.read_bytes() != data:
                raise ValueError(f'{path.name}: existing release configuration differs')
            if not path.exists():
                atomic_write(path, data)
        configs[service] = (
            '[Service]\n'
            f'EnvironmentFile={env_path}\n'
            'UMask=0077\nExecStart=\n'
            f'ExecStart={binary} {ROOT}/runtime/repos/{repo}/WORKFLOW.md '
            f'--logs-root {ROOT}/{logs} --port {port} '
            '--i-understand-that-this-will-be-running-without-the-usual-guardrails\n'
        ).encode()
    return before, configs


def activate(configs, before, backup, binary):
    previous = {service: dropin(service).read_bytes() if dropin(service).exists() else None
                for service in SERVICES}
    backup.mkdir(mode=0o700)
    atomic_write(backup / 'before.json', json.dumps(before, indent=2).encode())
    for service, data in previous.items():
        if data is not None:
            atomic_write(backup / f'{service}.conf', data)
    try:
        systemctl('stop', *SERVICES)
        for service, data in configs.items():
            atomic_write(dropin(service), data)
        systemctl('daemon-reload')
        expected = dict.fromkeys(SERVICES, str(binary))
        systemctl('start', *SERVICES)
        await_healthy(expected)
    except BaseException:
        print('Deploy failed; restoring the previous service configuration.', flush=True)
        try:
            # Try restoration even when stopping an unhealthy candidate reports an error.
            try:
                systemctl('stop', *SERVICES)
            except subprocess.SubprocessError:
                pass
            for service, data in previous.items():
                if data is None:
                    dropin(service).unlink(missing_ok=True)
                else:
                    atomic_write(dropin(service), data)
            systemctl('daemon-reload')
            systemctl('start', *SERVICES)
            await_healthy(before)
        except Exception as rollback_error:
            raise RuntimeError(f'Rollback failed; manual recovery required: {rollback_error}') from rollback_error
        print('Rollback succeeded; deployment still fails.', flush=True)
        raise


def main():
    if len(sys.argv) != 3 or not re.fullmatch(r'[0-9a-f]{40}', sys.argv[1]):
        raise ValueError('Usage: deploy_symphony.py <40-character SHA> <candidate directory>')
    sha, candidate = sys.argv[1], Path(sys.argv[2]).resolve()
    runtime = ROOT / 'runtime'
    (runtime / 'locks').mkdir(mode=0o700, exist_ok=True)
    with (runtime / 'locks/cd.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before, configs = prepare(sha, candidate, runtime / 'releases' / sha)
        binary = runtime / 'releases' / sha / 'symphony'
        # shortcut: retain old releases/install directories; add pruning when disk usage requires it.
        if all(path == str(binary) for path in before.values()):
            await_healthy(before)
            print(f'{sha} is already deployed and healthy; no restart needed.', flush=True)
            return
        activate(configs, before, candidate / 'backup', binary)
        print(f'Deployed {sha}; all four services are healthy.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'Deployment failed: {error}', file=sys.stderr, flush=True)
        sys.exit(1)
