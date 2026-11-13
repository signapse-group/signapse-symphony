#!/usr/bin/env python3
"""Install the grouped FE/QA browser gate from two reviewed source revisions."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


RUNTIME = Path('/opt/apps/symphony/runtime')
QA_REVISION = '484641caa232674fcc4f5ab0bd5d985bf4775720'
LOCK = Path('locks/signapse-ui-integration.lock')
STATE = Path('locks/browser-lease')
MCP = Path('ops/qa-playwright-mcp-20261112-CmsvYqQl')
FILES = (
    ('qa', 'scripts/runtime/browser_lease.py', 'browser_lease.py', 0o750),
    ('qa', 'scripts/runtime/qa-account-pool.py', 'qa-account-pool.py', 0o755),
    ('symphony', 'ops/grouped/run-fe-browser', 'run-fe-browser', 0o700),
    ('symphony', 'ops/grouped/playwright-browser-lease.cjs', str(MCP / 'playwright-browser-lease.cjs'), 0o640),
    ('symphony', 'ops/grouped/playwright-mcp', str(MCP / 'playwright-mcp'), 0o750),
)


def regular(path):
    if path.resolve() != path or not path.is_file():
        raise ValueError(f'Expected a regular canonical file: {path}')
    return path


def file_mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def describe(path):
    if not path.exists() and not path.is_symlink():
        return None
    return {'sha256': hashlib.sha256(regular(path).read_bytes()).hexdigest(), 'mode': file_mode(path)}


def atomic_write(path, data, mode):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.' + path.name + '.', delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(data)
            output.flush()
            os.fchmod(output.fileno(), mode)
            os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


@contextmanager
def deployment_lock():
    lock = regular(RUNTIME / LOCK)
    if lock.stat().st_uid != os.getuid():
        raise ValueError('Run as the owner of the host browser lock')
    with lock.open('rb') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def validate_state():
    state = RUNTIME / STATE
    if state.resolve() != state or not state.is_dir() or file_mode(state) != 0o700 or state.stat().st_uid != os.getuid():
        raise ValueError('Browser lease state directory must be canonical and owned by the runtime user with mode 0700')


def lock_id():
    lock = regular(RUNTIME / LOCK).stat()
    return [lock.st_dev, lock.st_ino]


def read_receipt(backup):
    receipt = json.loads(regular(backup / 'receipt.json').read_text())
    if receipt['lock'] != lock_id() or set(receipt['files']) != {dest for _, _, dest, _ in FILES}:
        raise ValueError('Browser lease backup does not match this runtime')
    return receipt


def verify(backup):
    validate_state()
    receipt = read_receipt(backup)
    for dest, entry in receipt['files'].items():
        if describe(RUNTIME / dest) != entry['after']:
            raise ValueError(f'Installed file differs from receipt: {dest}')
    return receipt


def restore(backup, receipt):
    for dest, entry in receipt['files'].items():
        if describe(backup / 'before' / dest) != entry['before']:
            raise ValueError(f'Backup file differs from receipt: {dest}')
    for dest, entry in reversed(receipt['files'].items()):
        path = RUNTIME / dest
        if describe(path) not in (entry['before'], entry['after']):
            raise ValueError(f'Current file differs from both revisions: {dest}')
    for dest, entry in reversed(receipt['files'].items()):
        path = RUNTIME / dest
        if entry['before'] is None:
            path.unlink(missing_ok=True)
        else:
            atomic_write(path, (backup / 'before' / dest).read_bytes(), entry['before']['mode'])
    for dest, entry in receipt['files'].items():
        if describe(RUNTIME / dest) != entry['before']:
            raise ValueError(f'Rollback verification failed: {dest}')


def apply(roots, shas, backup):
    if any(not re.fullmatch(r'[a-f0-9]{40}', sha) for sha in shas.values()):
        raise ValueError('Use full reviewed Git SHAs')
    if shas['qa'] != QA_REVISION:
        raise ValueError(f'Use the pinned QA revision {QA_REVISION}')
    regular(RUNTIME / MCP / 'qa-codex')
    staged = {}
    receipt = {'revisions': shas, 'lock': lock_id(), 'files': {}}
    for repo, source, dest, mode in FILES:
        data = regular(roots[repo] / source).read_bytes()
        if not data or b'\r\n' in data:
            raise ValueError(f'Stage Linux files from git archive: {source}')
        staged[dest] = data
        receipt['files'][dest] = {
            'before': describe(RUNTIME / dest),
            'after': {'sha256': hashlib.sha256(data).hexdigest(), 'mode': mode},
        }
    (RUNTIME / STATE).mkdir(mode=0o700, exist_ok=True)
    validate_state()
    if (backup / 'receipt.json').is_file():
        installed = verify(backup)
        if installed['revisions'] != shas or any(
            installed['files'][dest]['after'] != entry['after'] for dest, entry in receipt['files'].items()
        ):
            raise ValueError('Existing receipt names a different browser release')
        return installed
    backup.mkdir(mode=0o700)
    for dest, entry in receipt['files'].items():
        if entry['before'] is not None:
            path = backup / 'before' / dest
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            atomic_write(path, (RUNTIME / dest).read_bytes(), entry['before']['mode'])
    atomic_write(backup / 'receipt.json', (json.dumps(receipt, indent=2) + '\n').encode(), 0o600)
    try:
        for dest, entry in receipt['files'].items():
            atomic_write(RUNTIME / dest, staged[dest], entry['after']['mode'])
        return verify(backup)
    except BaseException:
        restore(backup, receipt)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    install = commands.add_parser('apply')
    install.add_argument('symphony_source', type=Path)
    install.add_argument('qa_source', type=Path)
    install.add_argument('backup', type=Path)
    install.add_argument('--symphony-sha', required=True)
    install.add_argument('--qa-sha', required=True)
    for command in ('verify', 'rollback'):
        commands.add_parser(command).add_argument('backup', type=Path)
    args = parser.parse_args()
    backup = args.backup.resolve()
    try:
        if args.command == 'verify':
            receipt = verify(backup)
        else:
            with deployment_lock():
                if args.command == 'apply':
                    roots = {'symphony': args.symphony_source.resolve(), 'qa': args.qa_source.resolve()}
                    receipt = apply(roots, {'symphony': args.symphony_sha, 'qa': args.qa_sha}, backup)
                else:
                    receipt = read_receipt(backup)
                    restore(backup, receipt)
        print(json.dumps({'action': args.command, 'backup': str(backup), **receipt}, indent=2))
    except (OSError, ValueError, KeyError) as error:
        print(f'Browser wrapper installation failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
