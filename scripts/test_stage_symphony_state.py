from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from deploy_symphony import PROFILES
from stage_symphony_state import stage


class StageStateTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.profiles = {}
        self.assignments = []
        for index, identity in enumerate(PROFILES, 10001):
            source = self.root / f'{("be" if identity == "landing" else identity)}.sqlite3'
            self.profiles[identity] = {
                'source': str(source),
                'workspace_root': str(self.root / 'workspaces' / identity),
                'desired': {'mode': 'running' if identity in {'landing', 'planning'} else 'paused', 'changed_at': '2026-11-13T06:00:00Z'},
            }
            self.assignments.append({'profile_id': identity, 'issue_id': str(index)})
            with closing(sqlite3.connect(source)) as db, db:
                db.executescript(
                    'CREATE TABLE IF NOT EXISTS active_turns (token TEXT);'
                    'CREATE TABLE IF NOT EXISTS runtime_control (id, mode, reason, source, changed_at, version, quota_summary, quota_checked_at);'
                    'CREATE TABLE IF NOT EXISTS pending_retries (runtime_id, issue_id, payload);'
                    "INSERT INTO runtime_control SELECT 1, 'paused', NULL, 'maintenance', '2026-11-13T06:10:00Z', 2, NULL, NULL "
                    'WHERE NOT EXISTS (SELECT 1 FROM runtime_control);'
                )
                db.execute('INSERT INTO pending_retries VALUES (?, ?, ?)',
                           (identity, str(index), json.dumps({'issue_id': str(index)})))
        self.config = {
            'tracker_base_url': 'https://jira.invalid',
            'project_key': 'SIGN',
            'profiles': self.profiles,
            'assignments': self.assignments,
        }
        self.output = self.root / 'staged'

    def test_shared_database_splits_retries_and_stages_every_profile_paused(self):
        stage(self.config, self.output)
        for identity in PROFILES:
            with closing(sqlite3.connect(self.output / f'{identity}.sqlite3')) as db, db:
                mode, reason = db.execute('SELECT mode, reason FROM runtime_control').fetchone()
                self.assertEqual(mode, 'paused')
                self.assertEqual(reason, 'Topology handoff' if identity in {'landing', 'planning'} else None)
                self.assertEqual(db.execute('SELECT runtime_id FROM pending_retries').fetchall(), [(identity,)])
        with closing(sqlite3.connect(self.output / 'assignment-owners.sqlite3')) as db, db:
            rows = db.execute('SELECT profile_id, issue_id FROM assignment_owners ORDER BY issue_id').fetchall()
        self.assertEqual(rows, [(row['profile_id'], row['issue_id']) for row in self.assignments])
        with closing(sqlite3.connect(self.profiles['be']['source'])) as db, db:
            self.assertEqual(db.execute('SELECT count(*) FROM pending_retries').fetchone()[0], 2)

    def test_rollback_can_restore_latest_distinct_modes(self):
        stage(self.config, self.output, restore_desired=True)
        for identity in PROFILES:
            with closing(sqlite3.connect(self.output / f'{identity}.sqlite3')) as db, db:
                self.assertEqual(db.execute('SELECT mode FROM runtime_control').fetchone(),
                                 (self.profiles[identity]['desired']['mode'],))

    def test_active_turn_or_unreconciled_retry_leaves_no_candidate(self):
        with closing(sqlite3.connect(self.profiles['be']['source'])) as db, db:
            db.execute("INSERT INTO active_turns VALUES ('live')")
        with self.assertRaisesRegex(ValueError, 'active turns'):
            stage(self.config, self.output)
        self.assertFalse(self.output.exists())
        with closing(sqlite3.connect(self.profiles['be']['source'])) as db, db:
            db.execute('DELETE FROM active_turns')
        self.assignments.pop()
        with self.assertRaisesRegex(ValueError, 'reconcile and inventory retry'):
            stage(self.config, self.output)
        self.assertFalse(self.output.exists())

    def test_retry_payload_must_match_owner_and_workspace_root(self):
        source = self.profiles['be']['source']
        with closing(sqlite3.connect(source)) as db, db:
            db.execute("UPDATE pending_retries SET payload = '{}' WHERE runtime_id = 'be'")
        with self.assertRaisesRegex(ValueError, 'different Jira ID'):
            stage(self.config, self.output)
        with closing(sqlite3.connect(source)) as db, db:
            payload = {'issue_id': '10002', 'workspace_path': self.profiles['landing']['workspace_root']}
            db.execute("UPDATE pending_retries SET payload = ? WHERE runtime_id = 'be'", (json.dumps(payload),))
        with self.assertRaisesRegex(ValueError, 'workspace leaves its profile root'):
            stage(self.config, self.output)
        self.assertFalse(self.output.exists())
