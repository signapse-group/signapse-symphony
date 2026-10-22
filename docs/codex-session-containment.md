# Codex session containment

Decision and implementation scope: 2026-10-16. Local and SSH boundary workers use
the same Linux/systemd containment. Source changes are verified before a direct
push to main; existing CI/CD builds and deploys all four services together.
Deployment health is separate from the post-deploy phase-boundary canary.

## Lifecycle

Each boundary session gets a randomly named symphony-session-<128-bit token>.service.
A transient service is used instead of a bare scope so systemd can kill every
remaining descendant when the session's main guard exits. This includes processes
that change process group, call setsid, or double-fork and reparent.

The execution host needs Python 3.9+, bash, systemd-run/systemctl, a reachable user
manager, and cgroup v2. For SSH these prerequisites, including its user bus, apply
on the remote host. Unsupported hosts fail startup; there is no process-group
fallback. The Python guard is embedded in the compiled client and sent over the
existing launch transport; no helper installation on remote workers is required.

1. Register the unique unit with the orchestrator synchronously and persist recovery
   before host launch. The guard checks its actual cgroup/unit identity and reports
   its systemd invocation ID. Register that identity before acknowledging startup.
   Codex cannot start before that acknowledgement.
2. The guard passes the existing filtered caller environment, cwd and stdio protocol
   to Codex. Its heartbeat/start frames are consumed outside the Codex protocol.
   Environment values do not enter the systemd-run argument list.
3. A host-side 15-second lease is refreshed every second by an Elixir process that
   monitors both the worker and scheduler owner. EOF closes the guard immediately.
   Lost connectivity or a dead owner ends renewal; lease expiry exits the guard.
   systemd then stops the complete cgroup, with a one-second stop grace period.
   Local sessions also bind to their owning user service when one is identifiable.
   A disconnected SSH session is terminated, never reattached to a continuing turn.
4. Boundary handoff persists recovery, suspends the old worker, kills only its unit
   and confirms the cgroup subtree has no live processes before terminating the
   worker. A fresh worker/thread still goes through existing live admission and
   receives the full phase prompt in the preserved workspace.
5. The same containment stop is required before terminal/route/stall/blocked cleanup
   or retry after worker death. Normal completion and failed initialization also
   stop the unit. Required cleanup does not depend on an Elixir after block running
   after an untrappable worker exit.

An allocated unit and the invocation ID are kept in the existing retry JSON; no
database schema migration is needed. A missing unit is successful only for an
identity already acknowledged from the host. Query failure, timeout, identity
mismatch, or uncertain startup retains claim/capacity and recovery for inspection.
Polling does not repeatedly retry an uncertain stop. The API exposes handoff_error
and last_error while the dashboard shows operator intervention; the issue remains
in running ownership rather than moving to the distinct blocked collection.

After a service/scheduler restart, a pending session recovery record pauses its
existing control membership. An operator verifies the old unit/processes are gone
before Resume. BE/FE/landing share control; QA has its own control database.
Preserve workspaces, uncommitted output and Jira states. Never remove retry markers
by hand to bypass recovery. The guard is process lifecycle management, not a sandbox
against an agent deliberately using host privileges or external service APIs.

## Verification and rollout

Run with a real user manager and disposable loopback sshd:

    cd elixir
    python3 ../scripts/run_session_tests.py make all
    python3 ../scripts/run_session_tests.py python3 -m unittest discover -s ../scripts -p 'test_*.py'

The SSH harness uses temporary keys/config, listens on loopback only, and removes
its own sshd after the checks. It neither reads production SSH keys nor edits sshd
configuration. CI provisions its disposable runner's user manager and runs this
same harness. The usual opt-in live-provider tests remain separate.

Coverage includes separate groups, daemonized/reparented writers, preserved cwd and
literal protocol/environment, two sessions, idempotent stop, wrong/missing identity,
query failure, startup acknowledgement, expired lease with open stdin, real SSH
disconnect, owner-service death, worker crash before retry, retained ownership after
unconfirmed terminal stop, UI/API errors, restart recovery, and all three phase
transitions locally and over SSH.

Before push/deploy, capture queue/workspace/control/recovery and binary metadata,
back up both SQLite databases using their backup API, and pause both memberships.
The existing CD restarts all four services; do not wait indefinitely for the
already suspended SIGN-183 worker to drain. Verify old processes and the old
service cgroups are gone after restart. Confirm the delivered SHA and paused
recovery before quota-checked Resume. SIGN-183 resumes at its live Progress state
with a fresh thread and the existing workspace; do not reset it to Ready.

After deployment, require real boundary evidence on the new build, including a
new thread, preserved output and no remaining old-session cgroup/process. Verify
all four services' revision/health/control, and report provider/feature acceptance
separately. Automatic CD rollback covers startup/health failures; a behavior failure
requires pausing affected work and preserving recovery before deciding rollback.
The prior binary still has the process-group containment defect.
