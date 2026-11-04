#!/usr/bin/env python3
"""Bounded host housekeeping. No workspace, volume, or agent-state pruning."""
import argparse
import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid

RUNTIME = Path('/opt/apps/symphony/runtime')
CACHE = Path('/var/cache/signapse-agent-temp')
CGROUP = Path('/sys/fs/cgroup')
GH = RUNTIME / 'agent-tools/bin/gh'
API_REPO = 'dgminhtam/signapse'
IMAGE_REPO = 'dgminhtam/signapse-api'
DAY = 86400
SESSION = re.compile(r'/user.slice/user-1000.slice/user@1000.service/app.slice/symphony-session-[a-f0-9]+\.service')
IMAGE = re.compile(r'sha256:[a-f0-9]{64}')


def log(event, **fields):
    print(json.dumps({'event': event, **fields}), flush=True)


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if result.returncode:
        # Command output can contain credentials or application logs.
        raise RuntimeError(f'{args[0]} exited {result.returncode}')
    return result.stdout


def atomic_json(path, value):
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = '.owner-' + uuid.uuid4().hex
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output)
        os.replace(temporary, path.name, src_dir_fd=directory, dst_dir_fd=directory)
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass
        os.close(directory)


@contextlib.contextmanager
def locked(path, create=False):
    flags = os.O_RDWR | os.O_NOFOLLOW
    if create:
        flags |= os.O_CREAT
    fd = os.open(path, flags, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield fd
    finally:
        os.close(fd)


def pressure_high():
    for resource, limit in [('io', 5), ('memory', 1)]:
        lines = Path(f'/proc/pressure/{resource}').read_text().splitlines()
        full = next(line for line in lines if line.startswith('full '))
        values = dict(item.split('=') for item in full.split()[1:])
        if float(values['avg10']) > limit:
            return True
    return False


def referenced(root):
    """Additional check, never a substitute for a closed owner and lease."""
    prefix = str(root)
    def contains(value):
        return value == prefix or value.startswith(prefix + '/')
    for process in Path('/proc').iterdir():
        if not process.name.isdigit() or int(process.name) == os.getpid():
            continue
        try:
            for name in ['cwd', 'exe', 'root']:
                try:
                    if contains(os.readlink(process / name)):
                        return True
                except (FileNotFoundError, ProcessLookupError):
                    pass
            if prefix in (process / 'cmdline').read_text(errors='replace'):
                return True
            for fd in (process / 'fd').iterdir():
                try:
                    if contains(os.readlink(fd)):
                        return True
                except (FileNotFoundError, ProcessLookupError):
                    pass
            for line in (process / 'maps').read_text(errors='replace').splitlines():
                fields = line.split(maxsplit=5)
                if len(fields) == 6 and contains(fields[5]):
                    return True
        except (FileNotFoundError, ProcessLookupError):
            pass
        except (PermissionError, OSError):
            return True
    return False


def cache_due(marker, now):
    return (marker.get('version') == 1
            and bool(SESSION.fullmatch(marker.get('cgroup', '')))
            and isinstance(marker.get('completed_at'), (int, float))
            and isinstance(marker.get('unused_since'), (int, float))
            and now >= marker['unused_since'] + DAY)


def cleanup_caches(apply):
    if not CACHE.exists():
        return
    mounts = [line.split()[4] for line in Path('/proc/self/mountinfo').read_text().splitlines()]
    for root in sorted(CACHE.iterdir())[:100]:
        if pressure_high():
            log('cache_deferred', reason='host_pressure')
            return
        if not re.fullmatch(r'run-[a-f0-9]{32}', root.name) or root.is_symlink():
            continue
        try:
            if root.resolve().parent != CACHE or not root.is_dir():
                continue
            with locked(root / '.lease'):
                marker_path = root / '.owner.json'
                if marker_path.is_symlink():
                    continue
                marker = json.loads(marker_path.read_text())
                if not isinstance(marker, dict):
                    continue
                if not SESSION.fullmatch(marker.get('cgroup', '')) or 'completed_at' not in marker:
                    log('cache_preserved', path=str(root), reason='unknown_or_incomplete_owner')
                    continue
                cgroup = CGROUP / marker['cgroup'].lstrip('/')
                if cgroup.exists() or referenced(root):
                    if apply and 'unused_since' in marker:
                        marker.pop('unused_since')
                        atomic_json(marker_path, marker)
                    log('cache_preserved', path=str(root), reason='owner_or_reference_active')
                    continue
                if 'unused_since' not in marker:
                    if apply:
                        marker['unused_since'] = time.time()
                        atomic_json(marker_path, marker)
                    log('cache_observed_unused', path=str(root), grace_hours=24)
                    continue
                if not cache_due(marker, time.time()):
                    continue
                if any(m == str(root) or m.startswith(str(root) + '/') for m in mounts):
                    log('cache_preserved', path=str(root), reason='mount')
                    continue
                log('cache_candidate', path=str(root), apply=apply)
                if apply:
                    # rmtree's fd-based traversal does not follow replaced symlinks.
                    assert shutil.rmtree.avoids_symlink_attacks
                    parent_fd = os.open(CACHE, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                    try:
                        shutil.rmtree(root.name, dir_fd=parent_fd)
                    finally:
                        os.close(parent_fd)
                    log('cache_removed', path=str(root))
        except (OSError, ValueError, TypeError) as error:
            log('cache_preserved', path=str(root), reason=type(error).__name__)


def successful_api_revisions():
    """Use actual readiness receipts, not a green superseded deployment job."""
    gh = ('runuser', '-u', 'dgminhtam', '--', str(GH))
    runs = json.loads(command(*gh, 'api', f'repos/{API_REPO}/actions/workflows/deploy.yml/runs?branch=dev&status=success&per_page=15'))['workflow_runs']
    successful = []
    for run in runs:
        jobs = json.loads(command(*gh, 'api', f'repos/{API_REPO}/actions/runs/{run["id"]}/jobs?per_page=100'))['jobs']
        for job in jobs:
            if job['name'] != 'deploy' or job['conclusion'] != 'success':
                continue
            output = command(*gh, 'run', 'view', str(run['id']), '--repo', API_REPO, '--job', str(job['id']), '--log')
            receipts = re.findall(r'API dev ready: ([a-f0-9]{40}) \((sha256:[a-f0-9]{64})\)', output)
            for revision, digest in receipts:
                if revision == run['head_sha'] and revision not in successful:
                    successful.append(revision)
        if len(successful) >= 3:
            return successful[:3]
    raise RuntimeError('Cannot establish current and two successful rollback revisions')


def select_images(images, protected, revisions, now):
    if len(set(revisions)) != 3:
        raise ValueError('Three distinct successful revisions required')
    available = {(image.get('Config', {}).get('Labels') or {}).get('org.opencontainers.image.revision') for image in images}
    if not set(revisions).issubset(available):
        raise ValueError('Rollback images are missing locally')
    eligible = []
    for image in images:
        labels = image.get('Config', {}).get('Labels') or {}
        refs = (image.get('RepoDigests') or []) + (image.get('RepoTags') or [])
        if not refs or any(not (ref.startswith(IMAGE_REPO + '@') or ref.startswith(IMAGE_REPO + ':')) for ref in refs):
            continue
        created = dt.datetime.fromisoformat(image['Created'].replace('Z', '+00:00')).timestamp()
        if (image['Id'] not in protected
                and labels.get('org.opencontainers.image.revision') not in revisions
                and created < now - 7 * DAY):
            eligible.append(image['Id'])
    return eligible


def docker_cleanup(apply):
    # Other repositories have no verified rollback/deploy contract: preserve them.
    revisions = successful_api_revisions()
    with locked(Path('/opt/apps/signapse/.api-dev.lock')):
        containers = command('docker', 'container', 'ls', '-aq').split()
        info = json.loads(command('docker', 'inspect', *containers)) if containers else []
        current = next(c for c in info if c['Name'] == '/signapse-dev-api')
        current_image = json.loads(command('docker', 'image', 'inspect', current['Image']))[0]
        if current_image['Config']['Labels'].get('org.opencontainers.image.revision') != revisions[0]:
            raise RuntimeError('Deployment changed or latest successful receipt is unavailable')
        protected = {c['Image'] for c in info}
        ids = list(dict.fromkeys(command('docker', 'image', 'ls', '-q', '--no-trunc', IMAGE_REPO).split()))
        images = json.loads(command('docker', 'image', 'inspect', *ids)) if ids else []
        candidates = select_images(images, protected, revisions, time.time())
        log('docker_plan', eligible=len(candidates), retained_revisions=revisions, apply=apply)
        for image_id in candidates[:10]:
            if pressure_high():
                log('docker_deferred', reason='host_pressure')
                break
            if apply:
                command('docker', 'image', 'rm', image_id)
            log('docker_removed' if apply else 'docker_candidate', image=image_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Default is read-only dry-run')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        with locked(Path('/run/lock/signapse-cleanup.lock'), create=True):
            if pressure_high():
                log('deferred', reason='host_pressure')
                return
            cleanup_caches(args.apply)
            try:
                docker_cleanup(args.apply)
            except (RuntimeError, OSError, ValueError, KeyError, StopIteration, subprocess.TimeoutExpired) as error:
                log('docker_preserved', reason=str(error))
            if args.apply:
                command('journalctl', '--vacuum-size=1G', '--vacuum-time=14days')
            log('finished', apply=args.apply)
    except BlockingIOError:
        log('deferred', reason='cleanup_already_running')


if __name__ == '__main__':
    main()
