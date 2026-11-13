"""Stage drained Symphony control databases and assignment owners for handoff."""

import argparse
from contextlib import closing
import json
from pathlib import Path
import sqlite3

from deploy_symphony import PROFILES


def read_source(path):
    with closing(sqlite3.connect(f'{Path(path).resolve().as_uri()}?mode=ro', uri=True)) as db, db:
        db.execute('BEGIN')
        if db.execute('SELECT count(*) FROM active_turns').fetchone()[0]:
            raise ValueError('Cannot migrate a database with active turns')
        state = db.execute(
            'SELECT mode, reason, source, changed_at, version, quota_summary, quota_checked_at '
            'FROM runtime_control WHERE id = 1'
        ).fetchone()
        if not state or state[0] != 'paused':
            raise ValueError('Pause and drain the source runtime before staging')
        return state, db.execute(
            'SELECT runtime_id, issue_id, payload FROM pending_retries'
        ).fetchall()


def write_control(path, state, desired, retries):
    with closing(sqlite3.connect(path)) as db, db:
        db.executescript(
            'CREATE TABLE runtime_control (id INTEGER PRIMARY KEY CHECK (id = 1), '
            'mode TEXT NOT NULL, reason TEXT, source TEXT, changed_at TEXT, '
            'version INTEGER NOT NULL DEFAULT 0, quota_summary TEXT, quota_checked_at TEXT);'
            'CREATE TABLE pending_retries (runtime_id TEXT NOT NULL, issue_id TEXT NOT NULL, '
            'payload TEXT NOT NULL, PRIMARY KEY (runtime_id, issue_id));'
        )
        db.execute(
            'INSERT INTO runtime_control VALUES (1, ?, ?, ?, ?, ?, ?, ?)',
            (desired['mode'], desired.get('reason'), desired.get('source'),
             desired['changed_at'], state[4] + 1, state[5], state[6]),
        )
        db.executemany('INSERT INTO pending_retries VALUES (?, ?, ?)', retries)


def write_owners(path, authority, project, owners):
    with closing(sqlite3.connect(path)) as db, db:
        db.execute(
            'CREATE TABLE assignment_owners (tracker_base_url TEXT NOT NULL, '
            'project_key TEXT NOT NULL, issue_id TEXT NOT NULL, profile_id TEXT NOT NULL, '
            'workspace_root TEXT NOT NULL, PRIMARY KEY (tracker_base_url, project_key, issue_id))'
        )
        db.executemany(
            'INSERT INTO assignment_owners VALUES (?, ?, ?, ?, ?)',
            [(authority, project, issue_id, identity, root)
             for issue_id, (identity, root) in owners.items()],
        )


def stage(config, output, *, restore_desired=False):
    profiles = config['profiles']
    if set(profiles) != set(PROFILES):
        raise ValueError('Expected the five Symphony profiles')
    sources, roots, controls, owners = {}, {}, {}, {}
    for identity, profile in profiles.items():
        source, root = Path(profile['source']), Path(profile['workspace_root'])
        if not source.is_absolute() or not root.is_absolute():
            raise ValueError(f'{identity}: source and workspace root must be absolute')
        roots[identity] = root.resolve()
        desired = profile['desired']
        if desired['mode'] not in {'running', 'paused'} or not desired['changed_at']:
            raise ValueError(f'{identity}: supply desired state recorded before maintenance pause')
        source = source.resolve()
        if source not in sources:
            sources[source] = read_source(source)
        state, retries = sources[source]
        if not restore_desired and desired['mode'] == 'running':
            desired = {
                'mode': 'paused', 'reason': 'Topology handoff',
                'source': 'manual', 'changed_at': state[3],
            }
        controls[identity] = (state, desired, [row for row in retries if row[0] == identity])

    for source, (_, retries) in sources.items():
        for identity, issue_id, payload in retries:
            if identity not in profiles or Path(profiles[identity]['source']).resolve() != source:
                raise ValueError(f'{identity}: retry {issue_id} has no matching profile source')
            record = json.loads(payload)
            if not isinstance(record, dict) or record.get('issue_id') != issue_id:
                raise ValueError(f'{identity}: retry {issue_id} payload has a different Jira ID')
            workspace = record.get('workspace_path')
            if workspace is not None:
                path = Path(workspace).resolve()
                if not Path(workspace).is_absolute() or roots[identity] not in path.parents:
                    raise ValueError(f'{identity}: retry {issue_id} workspace leaves its profile root')

    for record in config['assignments']:
        identity, issue_id = record['profile_id'], record['issue_id']
        if not isinstance(issue_id, str) or not issue_id.isascii() or not issue_id.isdecimal():
            raise ValueError('Assignment issue_id must be a numeric Jira ID string')
        owner = (identity, str(roots[identity]))
        if owners.setdefault(issue_id, owner) != owner:
            raise ValueError(f'Conflicting ownership for Jira ID {issue_id}')
    for identity, (_, _, retries) in controls.items():
        for _, issue_id, _ in retries:
            if owners.get(issue_id) != (identity, str(roots[identity])):
                raise ValueError(f'{identity}: reconcile and inventory retry {issue_id} before staging')

    authority, project = config['tracker_base_url'], config['project_key']
    if not authority.startswith('https://') or not project or project != project.upper():
        raise ValueError('Supply the canonical Jira API base URL and uppercase project key')
    output.mkdir(mode=0o700)
    for identity, control in controls.items():
        write_control(output / f'{identity}.sqlite3', *control)
    write_owners(output / 'assignment-owners.sqlite3', authority, project, owners)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--restore-desired', action='store_true',
                        help='restore recorded modes when preparing legacy rollback after grouped shutdown')
    args = parser.parse_args()
    stage(json.loads(args.inventory.read_text()), args.output, restore_desired=args.restore_desired)
