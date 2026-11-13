import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import configure_user_slice as resources


BEFORE = dict(resources.LIMITS, MemoryHigh='6442450944',
              IOReadBandwidthMax='/dev/sda 80000000', IOWriteBandwidthMax='/dev/sda 40000000')
DEVICE = '8:0'


class HostResourceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.receipt = self.root / 'receipt' / 'before.json'
        self.slice = self.root / 'cgroup' / resources.UNIT
        self.slice.mkdir(parents=True)
        self.dropins = self.root / 'dropins'
        self.dropins.mkdir()
        self.set_calls = []
        self.fail = False
        for name, value in [('CGROUP', self.slice.parent), ('DROPINS', self.dropins),
                            ('systemctl', self.ctl)]:
            mock = patch.object(resources, name, value)
            mock.start()
            self.addCleanup(mock.stop)
        self.configure(BEFORE)

    def configure(self, limits):
        self.limits = limits.copy()
        for key, value in limits.items():
            lines = ['[Slice]']
            if key in resources.IO_LIMITS:
                lines.extend((f'{key}=', f'{key}=/dev/sdb 50000000'))
            lines.append(f'{key}={value}')
            resources.dropin(key).write_text('\n'.join(lines) + '\n')
        (self.slice / 'memory.high').write_text(limits['MemoryHigh'])
        (self.slice / 'memory.max').write_text(limits['MemoryMax'])
        rbps = limits['IOReadBandwidthMax'].split()[1]
        wbps = limits['IOWriteBandwidthMax'].split()[1]
        (self.slice / 'io.max').write_text(f'8:16 rbps=50000000 wbps=50000000\n{DEVICE} rbps={rbps} wbps={wbps}\n')

    def ctl(self, verb, *args):
        if verb == 'set-property':
            self.assertEqual(args[0], resources.UNIT)
            self.assertTrue(self.receipt.exists(), 'Must have a backup before mutating systemd')
            limits = dict(item.split('=', 1) for item in args[1:])
            self.assertEqual(set(limits), set(resources.LIMITS))
            self.set_calls.append(limits)
            if self.fail:
                self.fail = False
                # The manager and disk can change before the kernel receives all values.
                self.limits['MemoryHigh'] = limits['MemoryHigh']
                resources.dropin('MemoryHigh').write_text(f'[Slice]\nMemoryHigh={limits["MemoryHigh"]}\n')
                raise subprocess.CalledProcessError(1, 'systemctl')
            self.configure(limits)
            return ''

        self.assertEqual(verb, 'show')
        self.assertEqual(args[0], '--all')
        group = args[1]
        values = {
            'LoadState': 'loaded', 'ActiveState': 'active', 'ControlGroup': f'/{group}',
            **(self.limits if group == resources.UNIT else BEFORE),
            'MemoryLow': '2147483648', 'MemorySwapMax': 'infinity',
        }
        lines = []
        for prop in args[2:]:
            key = prop.removeprefix('--property=')
            if key in values:
                lines.append(f'{key}={values[key]}')
            if group == resources.UNIT and key in resources.IO_LIMITS:
                lines.append(f'{key}=/dev/sdb 50000000')
        return '\n'.join(lines)

    def test_apply_verify_reapply_and_rollback(self):
        before = resources.snapshot(DEVICE)
        result = resources.apply(DEVICE, self.receipt)
        self.assertEqual(result['status'], 'applied')
        after = resources.snapshot(DEVICE)
        self.assertEqual(after['limits'], resources.LIMITS)
        self.assertEqual(after['user_other'], before['user_other'])
        self.assertEqual(after['system_limits'], before['system_limits'])
        self.assertEqual(json.loads(self.receipt.read_text()), before)
        self.assertEqual(self.receipt.stat().st_mode & 0o777, 0o600)
        self.assertEqual(resources.apply(DEVICE, self.receipt)['status'], 'unchanged')
        self.assertEqual(self.set_calls, [resources.LIMITS])
        self.assertEqual(resources.rollback(DEVICE, self.receipt)['status'], 'rolled_back')
        self.assertEqual(resources.snapshot(DEVICE), before)
        self.assertEqual(resources.apply(DEVICE, self.receipt)['status'], 'applied')

    def test_partial_apply_rolls_back(self):
        before = resources.snapshot(DEVICE)
        self.fail = True
        with self.assertRaisesRegex(RuntimeError, 'Apply failed and rolled back'):
            resources.apply(DEVICE, self.receipt)
        self.assertEqual(self.set_calls, [resources.LIMITS, BEFORE])
        self.assertEqual(resources.snapshot(DEVICE), before)

    def test_refuses_wrong_device_or_persistent_drift_before_writing(self):
        with self.assertRaisesRegex(RuntimeError, 'matching value'):
            resources.apply('8:1', self.receipt)
        resources.dropin('MemoryHigh').write_text('[Slice]\nMemoryHigh=1\n')
        with self.assertRaisesRegex(RuntimeError, 'persistent configuration differs'):
            resources.apply(DEVICE, self.receipt)
        self.assertEqual(self.set_calls, [])
        self.assertFalse(self.receipt.exists())

    def test_refuses_apply_without_root(self):
        with patch.object(resources.os, 'geteuid', return_value=1000), patch.object(
            resources, 'device_number'
        ) as device, patch('sys.argv', ['configure_user_slice.py', 'apply', 'a' * 40]), patch('sys.stderr'):
            with self.assertRaisesRegex(SystemExit, '2'):
                resources.main()
        device.assert_not_called()
