import fcntl
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import install_grouped_browser as browser


class BrowserInstallerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name).resolve()
        self.runtime = root / 'runtime'
        self.backup = root / 'backup'
        self.roots = {repo: root / repo for repo in ('symphony', 'qa')}
        self.shas = {'symphony': 'a' * 40, 'qa': browser.QA_REVISION}
        self.before = {}
        self.lock = self.runtime / browser.LOCK
        self.lock.parent.mkdir(parents=True)
        self.lock.touch(mode=0o600)
        (self.runtime / browser.MCP).mkdir(parents=True)
        (self.runtime / browser.MCP / 'qa-codex').write_text('existing launcher\n')
        for repo, source, dest, _ in browser.FILES:
            path = self.roots[repo] / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f'candidate {source}\n')
            if dest in ('run-fe-browser', 'qa-account-pool.py', str(browser.MCP / 'playwright-mcp')):
                (self.runtime / dest).write_text(f'existing {dest}\n')
                (self.runtime / dest).chmod(0o700)
            self.before[dest] = browser.describe(self.runtime / dest)
        runtime = patch.object(browser, 'RUNTIME', self.runtime)
        runtime.start()
        self.addCleanup(runtime.stop)

    def apply(self):
        with browser.deployment_lock():
            return browser.apply(self.roots, self.shas, self.backup)

    def test_install_repeat_and_restore_keep_lock_inode(self):
        inode = self.lock.stat().st_ino
        first = self.apply()
        self.assertEqual(self.apply(), first)
        self.assertEqual(browser.verify(self.backup), first)
        self.assertEqual(first['revisions'], self.shas)
        self.assertEqual(browser.file_mode(self.runtime / browser.STATE), 0o700)
        for repo, source, dest, mode in browser.FILES:
            self.assertEqual((self.runtime / dest).read_bytes(), (self.roots[repo] / source).read_bytes())
            self.assertEqual(browser.file_mode(self.runtime / dest), mode)
        self.assertEqual(self.lock.stat().st_ino, inode)
        browser.restore(self.backup, browser.read_receipt(self.backup))
        self.assertEqual({dest: browser.describe(self.runtime / dest) for dest in self.before}, self.before)
        self.assertEqual(self.lock.stat().st_ino, inode)

    def test_rejects_busy_lock_and_drift(self):
        with self.lock.open('rb') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            with self.assertRaises(BlockingIOError):
                self.apply()
        self.assertFalse(self.backup.exists())
        first = self.apply()
        (self.runtime / 'run-fe-browser').write_text('unrelated edit\n')
        with self.assertRaisesRegex(ValueError, 'differs from receipt'):
            browser.verify(self.backup)
        with self.assertRaisesRegex(ValueError, 'differs from both revisions'):
            browser.restore(self.backup, first)
        self.assertEqual((self.runtime / 'run-fe-browser').read_text(), 'unrelated edit\n')

    def test_failed_write_restores_previous_wrappers(self):
        write = browser.atomic_write

        def fail_once(path, data, mode):
            if path == self.runtime / 'run-fe-browser' and data.startswith(b'candidate'):
                raise OSError('interrupted wrapper install')
            write(path, data, mode)

        with patch.object(browser, 'atomic_write', side_effect=fail_once):
            with self.assertRaisesRegex(OSError, 'interrupted'):
                self.apply()
        self.assertEqual({dest: browser.describe(self.runtime / dest) for dest in self.before}, self.before)
        receipt = json.loads((self.backup / 'receipt.json').read_text())
        self.assertEqual(receipt['lock'], [os.stat(self.lock).st_dev, os.stat(self.lock).st_ino])
