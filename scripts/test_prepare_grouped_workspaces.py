from contextlib import redirect_stdout
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


HOOKS = Path(__file__).resolve().parents[1] / 'ops/grouped'
QA_LOADER = importlib.machinery.SourceFileLoader('prepare_qa_workspace', str(HOOKS / 'prepare-qa-workspace'))
QA_SPEC = importlib.util.spec_from_loader(QA_LOADER.name, QA_LOADER)
qa = importlib.util.module_from_spec(QA_SPEC)
QA_LOADER.exec_module(qa)


class PrepareGroupedWorkspacesTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()

    def test_fe_copies_private_env_to_the_assignment_workspace(self):
        workspace = self.root / 'workspaces-fe' / 'SIGN-1'
        workspace.mkdir(parents=True)
        source = self.root / 'fixture.env'
        source.write_text('EXAMPLE=fixture\n')
        env = os.environ | {'SIGNAPSE_UI_APP_ENV': str(source), 'SYMPHONY_WORKSPACE_ROOT': str(workspace.parent)}
        command = ['sh', str(HOOKS / 'prepare-fe-workspace')]
        subprocess.run(command, cwd=workspace, env=env, check=True)
        copy = workspace / '.env.local'
        self.assertEqual(copy.read_text(), source.read_text())
        self.assertEqual(copy.stat().st_mode & 0o777, 0o600)
        failed = subprocess.run(command, cwd=self.root, env=env, capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse((self.root / '.env.local').exists())

    def test_qa_checks_the_pinned_root_and_preserves_existing_evidence(self):
        workspace = self.root / 'workspaces-qa-jira' / 'SIGN-2'
        workspace.mkdir(parents=True)
        (workspace / 'playwright.config.mjs').touch()
        stable = self.root / 'runtime/repos/signapse-qa'
        checker = stable / 'scripts/check-local-instructions.mjs'
        checker.parent.mkdir(parents=True)
        checker.touch()
        (self.root / 'runtime/README-qa-testing.md').touch()
        revision = self.root / 'instructions/qa/revisions/v1'
        revision.mkdir(parents=True)
        (revision / 'instructions.json').write_text(json.dumps({'profile_id': 'qa', 'revision': 'v1'}))
        evidence = self.root / 'logs-qa/evidence' / workspace.name
        evidence.mkdir(parents=True)
        (evidence / 'keep.txt').write_text('retained')

        env = {
            'SYMPHONY_PROFILE_ID': 'qa',
            'SYMPHONY_INSTRUCTIONS_ROOT': str(revision),
            'SYMPHONY_INSTRUCTIONS_REVISION': 'v1',
        }
        with patch.object(qa, 'APP', self.root), patch.dict(os.environ, env, clear=True), redirect_stdout(io.StringIO()):
            with patch.object(qa.subprocess, 'run') as run:
                qa.prepare(workspace)
                qa.prepare(workspace)
                self.assertEqual(run.call_count, 2)
                self.assertEqual(run.call_args.args[0][1:], [str(checker), str(revision)])
                self.assertEqual((workspace / 'artifacts').resolve(), evidence)
                self.assertEqual((evidence / 'keep.txt').read_text(), 'retained')
                os.environ['SYMPHONY_INSTRUCTIONS_REVISION'] = 'wrong'
                with self.assertRaisesRegex(ValueError, 'do not match'):
                    qa.prepare(workspace)
                self.assertEqual(run.call_count, 2)
