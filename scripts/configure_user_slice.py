#!/usr/bin/env python3
"""Install and verify the approved persistent limits on the Symphony host."""

import argparse
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess

from deploy_symphony import atomic_write
from host_cleanup import locked


HOST = 'dgminhtam'
UNIT = 'user.slice'
DEVICE = '/dev/sda'
CGROUP = Path('/sys/fs/cgroup')
DROPINS = Path('/etc/systemd/system.control/user.slice.d')
RECEIPTS = Path('/var/lib/symphony-host-resources')
LOCK = Path('/run/lock/symphony-host-resources.lock')
LIMITS = {
    'MemoryHigh': '8053063680',
    'MemoryMax': '8589934592',
    'IOReadBandwidthMax': f'{DEVICE} 200000000',
    'IOWriteBandwidthMax': f'{DEVICE} 100000000',
}
IO_LIMITS = {'IOReadBandwidthMax': 'rbps', 'IOWriteBandwidthMax': 'wbps'}
PROTECTED = ('MemoryLow', 'MemorySwapMax', 'IOReadIOPSMax', 'IOWriteIOPSMax')


def systemctl(*args):
    return subprocess.check_output(['/usr/bin/systemctl', '--system', *args], text=True, timeout=30).strip()


def properties(unit, names):
    result = {name: [] for name in names}
    for line in systemctl('show', '--all', unit, *(f'--property={name}' for name in names)).splitlines():
        name, value = line.split('=', 1)
        result[name].append(value)
    return {name: sorted(values) for name, values in result.items()}


def device_number():
    if socket.gethostname().split('.')[0] != HOST:
        raise RuntimeError(f'Expected Symphony host {HOST}')
    if not (CGROUP / 'cgroup.controllers').is_file():
        raise RuntimeError('Expected cgroup v2 at /sys/fs/cgroup')
    device = Path(DEVICE).stat()
    if not stat.S_ISBLK(device.st_mode):
        raise RuntimeError(f'Expected block device {DEVICE}')
    return f'{os.major(device.st_rdev)}:{os.minor(device.st_rdev)}'


def dropin(name):
    return DROPINS / f'50-{name}.conf'


def snapshot(device):
    fields = properties(UNIT, ('LoadState', 'ActiveState', 'ControlGroup', *LIMITS, *PROTECTED))
    if (fields['LoadState'], fields['ActiveState'], fields['ControlGroup']) != (
        ['loaded'], ['active'], [f'/{UNIT}']
    ):
        raise RuntimeError(f'Expected active system {UNIT} at /{UNIT}')

    group = CGROUP / UNIT
    io_rows = [line.split() for line in (group / 'io.max').read_text().splitlines()]
    io = next((dict(entry.split('=', 1) for entry in row[1:]) for row in io_rows if row[0] == device), {})
    kernel = {
        'MemoryHigh': (group / 'memory.high').read_text().strip(),
        'MemoryMax': (group / 'memory.max').read_text().strip(),
        **{name: io.get(key) for name, key in IO_LIMITS.items()},
    }
    limits = {}
    files = {}
    for name in LIMITS:
        values = fields.pop(name)
        path = dropin(name)
        data = path.read_bytes().decode('utf-8')
        # These existing control drop-ins are the persistent source of the approved host limits.
        prefix = f'{name}='
        configured = sorted(line[len(prefix):] for line in data.splitlines()
                            if line.startswith(prefix) and line != prefix)
        if not values or configured != values:
            raise RuntimeError(f'{path}: persistent configuration differs from systemd')
        selected = [value for value in values if value.startswith(f'{DEVICE} ')] if name in IO_LIMITS else values
        if len(selected) != 1 or selected[0].split()[-1] != kernel[name]:
            raise RuntimeError(f'{name}: expected one matching value in systemd and the kernel')
        limits[name] = selected[0]
        fields[name] = [value for value in values if value not in selected]
        files[name] = {'content': data, 'mode': stat.S_IMODE(path.stat().st_mode)}

    return {
        'host': HOST, 'device': device, 'limits': limits, 'dropins': files, 'user_other': fields,
        'system_limits': properties('system.slice', (*LIMITS, *PROTECTED)),
    }


def set_limits(limits):
    systemctl('set-property', UNIT, *(f'{key}={limits[key]}' for key in LIMITS))


def restore(device, previous):
    try:
        current = snapshot(device)
        if current['limits'] == previous['limits']:
            return current
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError):
        # A partial apply can leave systemd, the kernel, and the drop-ins out of sync.
        pass

    set_limits(previous['limits'])
    after = snapshot(device)
    if after['limits'] != previous['limits']:
        raise RuntimeError('Rollback limits differ from the pre-change receipt')
    return after


def apply(device, receipt):
    before = snapshot(device)
    if before['limits'] == LIMITS:
        return {'status': 'unchanged', 'backup': str(receipt) if receipt.exists() else None, 'after': before}
    if before['limits']['MemoryMax'] != LIMITS['MemoryMax']:
        raise RuntimeError('Expected the existing 8 GiB MemoryMax; refusing to change the hard limit')
    if receipt.exists():
        if json.loads(receipt.read_text()) != before:
            raise RuntimeError(f'{receipt}: existing backup differs from the current state')
    else:
        atomic_write(receipt, json.dumps(before, indent=2).encode())
    try:
        set_limits(LIMITS)
        after = snapshot(device)
        if after['limits'] != LIMITS or any(after[key] != before[key] for key in ('user_other', 'system_limits')):
            raise RuntimeError('Verification failed for approved limits or unrelated settings')
    except BaseException as error:
        try:
            restore(device, before)
        except Exception as recovery:
            raise RuntimeError(f'Apply failed ({error}); rollback failed ({recovery}); backup: {receipt}') from error
        raise RuntimeError(f'Apply failed and rolled back: {error}; backup: {receipt}') from error
    return {'status': 'applied', 'backup': str(receipt), 'before': before, 'after': after}


def rollback(device, receipt):
    previous = json.loads(receipt.read_text())
    if previous['host'] != HOST or previous['device'] != device:
        raise RuntimeError('Rollback receipt does not match this host and device')
    if set(previous['limits']) != set(LIMITS) or set(previous['dropins']) != set(LIMITS):
        raise RuntimeError('Rollback receipt does not contain the four managed properties')
    return {'status': 'rolled_back', 'backup': str(receipt), 'after': restore(device, previous)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('apply', 'verify', 'rollback'))
    parser.add_argument('release', nargs='?', help='verified main commit SHA (required for apply and rollback)')
    args = parser.parse_args()
    if args.action != 'verify':
        if not args.release or not re.fullmatch(r'[0-9a-f]{40}', args.release):
            parser.error('apply and rollback require a full main commit SHA')
        if os.geteuid() != 0:
            parser.error('apply and rollback require root via sudo')

    os.umask(0o077)
    device = device_number()
    if args.action == 'verify':
        current = snapshot(device)
        if current['limits'] != LIMITS:
            raise RuntimeError(f'Expected {LIMITS}, found {current["limits"]}')
        result = {'status': 'verified', 'after': current}
    else:
        with locked(LOCK, create=True):
            RECEIPTS.mkdir(mode=0o700, exist_ok=True)
            directory = RECEIPTS.lstat()
            if not stat.S_ISDIR(directory.st_mode) or directory.st_uid != 0 or stat.S_IMODE(directory.st_mode) != 0o700:
                raise RuntimeError(f'Expected a root-owned private directory at {RECEIPTS}')
            receipt = RECEIPTS / f'{args.release}.json'
            action = apply if args.action == 'apply' else rollback
            result = action(device, receipt)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(f'Host resources: {error}')
