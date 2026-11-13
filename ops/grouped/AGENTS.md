# Symphony deployment workspace

This directory contains the deployed runtime, logs, workspaces and operational
state. The Symphony source checkout is `runtime/source/`. Read its `AGENTS.md`
and `docs/symphony-grouped-rollout.md` before modifying the runtime or switching
ownership between services.

`symphony-grouped.service` owns FE, BE, QA, Landing and Planning after cutover.
It listens on loopback port 4000. The dashboard is served through Tailscale
HTTPS 443. Inspect the grouped unit and `/api/v1/state` for the active process
and profile readiness. The five legacy units and their configuration are
retained for rollback.

`runtime/grouped/profiles.json` binds each profile to a deployment workflow,
isolated environment, control database and instructions directory. Consumer
repositories own their workflow prompts and instructions. Prepare revisions
from those repositories and activate a validated revision for each profile.
Keep `revisions/` read-only and preserve active and previous revisions used by
running sessions.

Keep the five control databases separate, including BE and Landing. Preserve the
assignment owner database, workspace paths and branches. Keep QA's evidence,
account pool and browser wrapper, FE's integration lock, and Landing's browser
wrapper and cache. Use the profile's documented checks before changing these
inputs.

Keep secrets in protected deployment files and preserve each profile's access
grants. Use the cutover and rollback runbook to drain sessions, reconcile
external writes and restore saved operator intent. Keep a deployment receipt
with the verified release SHA, unit configuration and rollback artifacts.
