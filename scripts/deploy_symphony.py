"""Deploy a verified artifact to the active Symphony topology."""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.request


ROOT = Path('/opt/apps/symphony')
UNITS = Path.home() / '.config/systemd/user'
GROUPED_SERVICE = 'symphony-grouped.service'
PROFILES = {'fe': 2, 'be': 1, 'qa': 2, 'landing': 1, 'planning': 1}
LEGACY_SERVICES = (
    'symphony.service', 'symphony-fe.service', 'symphony-landing.service',
    'symphony-qa.service', 'symphony-planning.service',
)


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
    props = properties(GROUPED_SERVICE)
    if (props['ActiveState'] != 'active' or props['MainPID'] == '0'
            or props['ExecStart'] != expected[GROUPED_SERVICE]):
        raise RuntimeError('Grouped Symphony process or executable is not ready')
    with urllib.request.urlopen('http://127.0.0.1:4000/api/v1/state', timeout=5) as response:
        state = json.load(response)
    profiles = state.get('profiles', [])
    if (state.get('mode') != 'profiles' or state.get('health') != 'healthy'
            or len(profiles) != len(PROFILES)
            or {profile.get('profile_id') for profile in profiles} != set(PROFILES)):
        raise RuntimeError('Grouped Symphony does not report five healthy profiles')
    for profile in profiles:
        identity = profile['profile_id']
        control = profile.get('runtime_control', {})
        services = control.get('services', {})
        if (profile.get('health') != 'healthy' or profile.get('max_concurrent_agents') != PROFILES[identity]
                or not profile.get('workflow_revision') or not profile.get('instructions_revision')
                or not control.get('enabled') or control.get('database_error')
                or control.get('mode') not in {'running', 'paused', 'pausing', 'checking_quota'}
                or set(services) != {identity} or services[identity].get('status') != 'online'):
            raise RuntimeError(f'{identity}: grouped runtime, revision or heartbeat is not healthy')
    return [props['MainPID']]


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


def install_binary(candidate, release):
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

    return binary


def prepare_grouped(sha, candidate, release, *, initial=False):
    runtime = ROOT / 'runtime'
    manifest = runtime / 'grouped/profiles.json'
    environment = runtime / 'grouped/service.env'
    sys_config = runtime / 'grouped/sys.config'
    if not all(path.is_file() for path in (manifest, environment, sys_config)):
        raise RuntimeError('Grouped deployment inputs are incomplete')
    before = {}
    if not initial:
        props = properties(GROUPED_SERVICE)
        if props['ActiveState'] != 'active' or props['MainPID'] == '0':
            raise RuntimeError('Grouped deployment requires an active grouped service')
        before[GROUPED_SERVICE] = props['ExecStart']
    binary = install_binary(candidate, release)
    install = runtime / f'install-{sha}/grouped'
    install.mkdir(mode=0o700, parents=True, exist_ok=True)
    config = (
        '[Service]\n'
        f'EnvironmentFile={environment}\n'
        f'Environment="SYMPHONY_INSTALL_DIR={install}"\n'
        f'Environment="ERL_FLAGS=-config {sys_config.with_suffix("")}"\n'
        'UMask=0077\nExecStart=\n'
        f'ExecStart={binary} --profiles {manifest} --logs-root {ROOT}/logs-grouped --port 4000 '
        '--i-understand-that-this-will-be-running-without-the-usual-guardrails\n'
    ).encode()
    return before, {GROUPED_SERVICE: config}


def activate(configs, before, backup, binary):
    services = tuple(configs)
    previous = {service: dropin(service).read_bytes() if dropin(service).exists() else None
                for service in services}
    backup.mkdir(mode=0o700)
    atomic_write(backup / 'before.json', json.dumps(before, indent=2).encode())
    for service, data in previous.items():
        if data is not None:
            atomic_write(backup / f'{service}.conf', data)
    try:
        systemctl('stop', *services)
        for service, data in configs.items():
            atomic_write(dropin(service), data)
        systemctl('daemon-reload')
        expected = dict.fromkeys(services, str(binary))
        systemctl('start', *services)
        await_healthy(expected)
    except BaseException:
        print('Deploy failed; restoring the previous service configuration.', flush=True)
        try:
            # Try restoration even when stopping an unhealthy candidate reports an error.
            try:
                systemctl('stop', *services)
            except subprocess.SubprocessError:
                pass
            for service, data in previous.items():
                if data is None:
                    dropin(service).unlink(missing_ok=True)
                else:
                    atomic_write(dropin(service), data)
            systemctl('daemon-reload')
            systemctl('start', *services)
            await_healthy(before)
        except Exception as rollback_error:
            raise RuntimeError(f'Rollback failed; manual recovery required: {rollback_error}') from rollback_error
        print('Rollback succeeded; deployment still fails.', flush=True)
        raise


def main():
    if len(sys.argv) == 4 and sys.argv[1] == '--prepare-grouped':
        sha, candidate = parse_candidate(sys.argv[2:])
        _, configs = prepare_grouped(sha, candidate, ROOT / 'runtime/releases' / sha, initial=True)
        atomic_write(candidate / 'grouped-90-cd.conf', configs[GROUPED_SERVICE])
        print(f'Prepared {sha} and grouped-90-cd.conf; service configuration unchanged.', flush=True)
        return
    sha, candidate = parse_candidate(sys.argv[1:])
    runtime = ROOT / 'runtime'
    if not (runtime / 'grouped/cutover-complete').is_file():
        print('Grouped cutover has not been verified; automatic deployment skipped.', flush=True)
        return
    (runtime / 'locks').mkdir(mode=0o700, exist_ok=True)
    with (runtime / 'locks/cd.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not (runtime / 'grouped/cutover-complete').is_file():
            print('Grouped cutover has not been verified; automatic deployment skipped.', flush=True)
            return
        assert_legacy_stopped()
        before, configs = prepare_grouped(sha, candidate, runtime / 'releases' / sha)
        binary = runtime / 'releases' / sha / 'symphony'
        # shortcut: retain old releases/install directories; add pruning when disk usage requires it.
        if all(path == str(binary) for path in before.values()):
            await_healthy(before)
            print(f'{sha} is already deployed and healthy; no restart needed.', flush=True)
            return
        activate(configs, before, candidate / 'backup', binary)
        print(f'Deployed {sha}; five profiles are healthy.', flush=True)


def parse_candidate(args):
    if len(args) != 2 or not re.fullmatch(r'[0-9a-f]{40}', args[0]):
        raise ValueError('Usage: deploy_symphony.py [--prepare-grouped] <40-character SHA> <candidate directory>')
    return args[0], Path(args[1]).resolve()


def assert_legacy_stopped():
    for service in LEGACY_SERVICES:
        state = systemctl('show', service, '-p', 'ActiveState', '--value')
        if state != 'inactive':
            raise RuntimeError(f'{service}: expected inactive; found {state}')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'Deployment failed: {error}', file=sys.stderr, flush=True)
        sys.exit(1)
