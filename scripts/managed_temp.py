#!/usr/bin/env python3
"""Give a browser command private disposable cache; preserve its exit status."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path('/var/cache/signapse-agent-temp')


def main():
    if len(sys.argv) < 2:
        raise SystemExit('Pass the browser command and arguments')
    os.umask(0o077)
    root = ROOT / ('run-' + uuid.uuid4().hex)
    root.mkdir(mode=0o700)
    with (root / '.lease').open('x') as lease:
        fcntl.flock(lease, fcntl.LOCK_EX)
        cgroup = Path('/proc/self/cgroup').read_text().strip().removeprefix('0::')
        marker = {'version': 1, 'cgroup': cgroup}
        owner = root / '.owner.json'
        owner.write_text(json.dumps(marker))
        env = {**os.environ, 'TMPDIR': str(root)}
        result = subprocess.call(sys.argv[1:], env=env, pass_fds=(lease.fileno(),))
        marker['completed_at'] = time.time()
        owner.write_text(json.dumps(marker))
    raise SystemExit(result if result >= 0 else 128 - result)


if __name__ == '__main__':
    main()
