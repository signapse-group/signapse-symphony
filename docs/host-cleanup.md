# Host cleanup: scope A

The operator-approved policy (2026-11-04) covers Docker images, bounded logs,
and explicitly managed disposable cache only. It does not prune workspaces,
agent databases/session history, evidence, backups, volumes, or installed runtimes.

`scripts/host_cleanup.py` defaults to a read-only dry-run. `--apply` is run daily
by `signapse-cleanup.timer` at 03:30 Asia/Bangkok. The root maintenance service
is bounded to five minutes, 256 MiB, 20% of one CPU and low I/O priority. It
uses a nonblocking global lock and defers heavy work on elevated I/O/memory PSI.
Docker performs deletions in its daemon; the CLI resource limit is not a daemon
limit. Deletions are therefore bounded to ten images per run and checked for
pressure between images.

Installed programs live in root-owned `/usr/local/lib/signapse-cleanup`.
The GitHub credential wrapper runs as `dgminhtam`, never as root. The cache root
is `/var/cache/signapse-agent-temp`; application workspaces are not in its
allowlist. First rollout backup and before/after process/container identities
are under `runtime/ops/host-cleanup-20261104/installation-20261104T062516Z`.
The timer adds up to ten minutes of jitter to its daily start time.

Install the program directory as root with an explicit `chmod 0755` (a private
umask overrides mkdir's requested mode). Test `managed_temp.py` as the worker
user, including a nonzero command exit, **before** atomically updating wrappers.
During the first rollout this directory initially had mode 0700; one SIGN-479
browser invocation failed to launch. The mode was corrected and the installed
worker-user canary passed. No runtime or application container was restarted.

The follow-up on SIGN-479 at candidate `5bee03e0acfd329cb2f9dee6e0a57a059ffd7039`
ran both previously blocked browser cases as `dgminhtam` through `run-fe-browser`
and its shared lock. Playwright launched without permission errors. Both cases
reached assertions and failed: the responsive Next locator matched two buttons
(`market-chart.spec.ts:983`), and the timed-refresh request count stayed at three
(`market-chart.spec.ts:1788`). This verifies runner access, not FE acceptance.
Logs, screenshots and traces are retained under
`runtime/ops/host-cleanup-20261104/sign479-recheck-20261104`.

## Docker

The API deploy workflow's actual readiness receipts establish the latest three
distinct successful revisions: current plus two rollback revisions. A green
superseded job is insufficient. Fetches use the existing host `gh` credential
wrapper without copying credentials into config or command-line arguments.
Under the existing `.api-dev.lock`, all container image references are protected.
Only images owned exclusively by `dgminhtam/signapse-api`, older than seven days,
outside those protected sets are candidates. Removal never uses force.

Missing receipts, missing rollback images, GitHub failures, a changed current
deployment or a busy deploy lock skip image deletion. Other repositories,
including MDG, remain protected until their successful rollback/deploy contract
is verifiable; this is deliberate fail-closed behavior, not permission to prune
them by image age. Manual API deployment must honor the same deployment lock.

## Disposable cache

`scripts/managed_temp.py` wraps new browser invocations, retaining the original
command, exit code, credentials and existing browser locks. It assigns a unique
TMPDIR under `/var/cache/signapse-agent-temp`, holds a lease, and records the owning
Symphony session cgroup plus command completion. It never redirects test reports
or QA recovery state. Existing invocations and their old TMPDIRs are untouched.

The cleaner requires completion, disappearance of the owner cgroup, an available
lease and no process references. The first such observation starts a 24-hour
grace period. Active references reset that period. Unknown, crashed or unmarked
directories are preserved. Files outside the allowlisted managed cache root,
including legacy shared cache, are never automatically deleted. Symlinks and
mount boundaries cannot redirect deletion outside a candidate.

## Logs and operation

Journald is capped at 1 GiB and fourteen days; the size ceiling takes precedence.
Docker Compose logging is capped at `20m` times five files, retaining stricter
existing limits. These container options take effect on normal future deployment;
installation does not recreate containers. Docker log files are never manually
deleted or truncated. Evidence is outside log expiry.

Inspect `journalctl -u signapse-cleanup.service` for decisions and skip reasons.
Disable only `signapse-cleanup.timer` to stop automatic cleanup; this does not
pause or restart agents. Operator installation backups retain the original
wrappers and host logging configuration. Removed disposable cache regenerates;
removed images can be pulled by digest. Source/evidence is never removed.

Validate with `python3 -m unittest discover -s scripts -p test_host_cleanup.py` on
Linux, then run the deployed script without `--apply`. Check lease contention,
protected rollback sets and unchanged live agent/container identities before
enabling the timer. No Elixir runtime code is changed by this host utility.
The focused tests run without root: process scanning is limited to test-owned
processes, including a real child holding a cache reference; unreadable processes
are separately checked to preserve the fail-closed behavior.
