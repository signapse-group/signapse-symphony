import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
import subprocess
import sys
from unittest.mock import patch

import host_cleanup as cleanup
import managed_temp


class CacheSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.cache = self.base / 'cache'
        self.cache.mkdir()
        self.group = '/user.slice/user-1000.slice/user@1000.service/app.slice/symphony-session-abc123.service'
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(cleanup, 'CACHE', self.cache))
        self.stack.enter_context(patch.object(cleanup, 'CGROUP', self.base / 'groups'))
        self.stack.enter_context(patch.object(cleanup, 'pressure_high', return_value=False))
        # Inspect only test-owned processes; unrelated /proc permissions vary in CI.
        self.processes = []
        iterdir = Path.iterdir
        self.stack.enter_context(patch.object(Path, 'iterdir', lambda path:
            iter(self.processes) if path == Path('/proc') else iterdir(path)))
        self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.root = self.cache / ('run-' + 'a' * 32)
        self.root.mkdir()
        (self.root / '.lease').touch()
        self.marker = {'version': 1, 'cgroup': self.group, 'completed_at': time.time() - 3 * cleanup.DAY, 'unused_since': time.time() - 2 * cleanup.DAY}
        self.save()

    def save(self):
        (self.root / '.owner.json').write_text(json.dumps(self.marker))

    def test_dry_run_preserves_eligible_directory(self):
        cleanup.cleanup_caches(False)
        self.assertTrue(self.root.exists())

    def test_expired_closed_cache_removed_without_following_nested_symlink(self):
        outside = self.base / 'important-source'
        outside.write_text('preserve')
        (self.root / 'link').symlink_to(outside)
        cleanup.cleanup_caches(True)
        self.assertFalse(self.root.exists())
        self.assertEqual(outside.read_text(), 'preserve')

    def test_live_lease_blocks_cleanup(self):
        with (self.root / '.lease').open('r+') as lease:
            fcntl.flock(lease, fcntl.LOCK_EX)
            cleanup.cleanup_caches(True)
        self.assertTrue(self.root.exists())

    def test_running_owner_resets_grace(self):
        (cleanup.CGROUP / self.group.lstrip('/')).mkdir(parents=True)
        cleanup.cleanup_caches(True)
        self.assertNotIn('unused_since', json.loads((self.root / '.owner.json').read_text()))
        self.assertTrue(self.root.exists())

    def test_real_open_file_prevents_deletion(self):
        child = subprocess.Popen([sys.executable, '-c', 'import sys,time; f=open(sys.argv[1],"w"); print("ready",flush=True); time.sleep(60)', str(self.root / 'open')], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'ready')
            self.processes.append(Path('/proc') / str(child.pid))
            cleanup.cleanup_caches(True)
            self.assertTrue(self.root.exists())
            self.assertNotIn('unused_since', json.loads((self.root / '.owner.json').read_text()))
        finally:
            child.terminate()
            child.wait(timeout=5)
            child.stdout.close()

    def test_unreadable_process_preserves_cache(self):
        self.processes.append(Path('/proc/1'))
        with patch.object(Path, 'read_text', side_effect=PermissionError):
            self.assertTrue(cleanup.referenced(self.root))

    def test_first_observation_starts_full_24_hour_grace(self):
        self.marker.pop('unused_since')
        self.save()
        cleanup.cleanup_caches(False)
        self.assertNotIn('unused_since', json.loads((self.root / '.owner.json').read_text()))
        cleanup.cleanup_caches(True)
        marker = json.loads((self.root / '.owner.json').read_text())
        self.assertFalse(cleanup.cache_due(marker, marker['unused_since'] + cleanup.DAY - 1))
        self.assertTrue(cleanup.cache_due(marker, marker['unused_since'] + cleanup.DAY))

    def test_unknown_owner_and_missing_completion_are_preserved(self):
        original = dict(self.marker)
        for changes in [{'cgroup': '/../../outside'}, {'completed_at': None}]:
            self.marker = dict(original)
            self.marker.update(changes)
            self.save()
            cleanup.cleanup_caches(True)
            self.assertTrue(self.root.exists())

    def test_high_pressure_defers_cleanup(self):
        with patch.object(cleanup, 'pressure_high', return_value=True):
            cleanup.cleanup_caches(True)
        self.assertTrue(self.root.exists())

    def test_marker_update_never_follows_a_preexisting_temporary_symlink(self):
        outside = self.base / 'private-file'
        outside.write_text('unchanged')
        (self.root / '.owner.new').symlink_to(outside)
        self.marker.pop('unused_since')
        self.save()
        cleanup.cleanup_caches(True)
        self.assertEqual(outside.read_text(), 'unchanged')
        self.assertIn('unused_since', json.loads((self.root / '.owner.json').read_text()))


class ImageSafetyTests(unittest.TestCase):
    def image(self, revision, days=10, repository=cleanup.IMAGE_REPO):
        return {'Id': 'sha256:' + revision * 64,
                'RepoDigests': [repository + '@sha256:' + revision * 64],
                'RepoTags': [],
                'Config': {'Labels': {'org.opencontainers.image.revision': revision}},
                'Created': cleanup.dt.datetime.fromtimestamp(time.time() - days * cleanup.DAY, cleanup.dt.timezone.utc).isoformat()}

    def test_current_two_rollbacks_all_container_references_and_young_images_survive(self):
        images = [self.image(x) for x in 'abcdef'] + [self.image('1', days=1), self.image('2', repository='other/repo')]
        result = cleanup.select_images(images, {images[3]['Id']}, ['a', 'b', 'c'], time.time())
        self.assertEqual(result, [images[4]['Id'], images[5]['Id']])

    def test_unknown_or_incomplete_rollback_inventory_rejects_all_deletion(self):
        images = [self.image('a')]
        with self.assertRaises(ValueError):
            cleanup.select_images(images, set(), ['a', 'b', 'c'], time.time())
        with self.assertRaises(ValueError):
            cleanup.select_images(images, set(), ['a', 'a', 'a'], time.time())

    def test_multi_repository_image_is_not_deleted(self):
        images = [self.image(x) for x in 'abcd']
        images[3]['RepoTags'] = ['somebody-else/rollback:keep']
        self.assertEqual(cleanup.select_images(images, set(), ['a', 'b', 'c'], time.time()), [])

    def test_successful_but_superseded_deploy_is_not_a_rollback_receipt(self):
        runs = {'workflow_runs': [{'id': 1, 'head_sha': 'a' * 40}]}
        jobs = {'jobs': [{'id': 2, 'name': 'deploy', 'conclusion': 'success'}]}
        with patch.object(cleanup, 'command', side_effect=[json.dumps(runs), json.dumps(jobs), 'Superseded dev revision; deployment skipped.']):
            with self.assertRaises(RuntimeError):
                cleanup.successful_api_revisions()


class TempWrapperTests(unittest.TestCase):
    def test_temp_is_isolated_and_command_failure_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(managed_temp, 'ROOT', Path(temp)), patch.object(sys, 'argv', ['managed_temp.py', sys.executable, '-c', 'import os,pathlib; pathlib.Path(os.environ["TMPDIR"],"cache").write_text("generated"); raise SystemExit(7)']):
                with self.assertRaises(SystemExit) as result:
                    managed_temp.main()
            self.assertEqual(result.exception.code, 7)
            roots = list(Path(temp).iterdir())
            self.assertEqual(len(roots), 1)
            self.assertEqual((roots[0] / 'cache').read_text(), 'generated')
            self.assertIn('completed_at', json.loads((roots[0] / '.owner.json').read_text()))
            with cleanup.locked(roots[0] / '.lease'):
                pass


if __name__ == '__main__':
    unittest.main()
