# Grouped Symphony rollout

Use the same versioned release, checksums and deployment lock for cutover,
rollback and later CD. The five legacy units remain recoverable. A candidate
uses `symphony-grouped.service` with its own drop-ins, a loopback listener on
4000, and an operator-owned profiles manifest. The initial change of ownership
is an operator action after the isolated rehearsal has passed.

## Moving an existing grouped service to checkout instructions

Match every live profile to the [manifest example](../ops/grouped/profiles.json.example).
`checkout_upstream` names the published repository and branch. `checkout_workflow`
is the repository-relative prompt path. Keep the operator-owned
`workflows/<profile>.md` YAML front matter, including its delimiters, commands
and sandbox settings. The consumer repository owns the Markdown/Liquid prompt,
`AGENTS.md` and skills.

1. Rehearse on a disposable workspace with an older topic branch. Publish
   instructions to a newer upstream commit and verify that a new worker attempt
   reports that `instructions_head` and prompt digest, preserves the task branch
   and outputs, and starts Codex in the issue workspace. An invalid or inaccessible
   upstream must pause only the affected profile with a checkout diagnostic.
   The QA prepare hook validates the upstream source and preserves the issue’s
   durable `artifacts` link.
2. Before a merge can trigger CD, record the five profiles’ desired states.
   Coordinate with CD under `runtime/locks/cd.lock` and the existing
   `runtime/grouped/cutover-complete` marker. Remove admission during the
   maintenance window, let active turns finish, verify contained sessions stop,
   and reconcile pending external writes. Keep operator-only backups of the
   verified release, manifest, workflow, hook and unit settings.
3. Deploy the verified release and the reviewed QA hook to its configured path.
   Use CD with the cutover marker present under its deployment lock. Keep control
   databases, assignment ownership, and workspace and evidence paths. After
   restart, verify installed SHA, healthy profiles, caps, heartbeat and
   `instructions_source: "checkout"`.
4. Run a QA canary on a published SHA with no staged instructions. In a real
   Codex session, confirm the five Playwright tools, the correct seed, Planner
   save, Generator log and write, and release of the browser lease. Verify the
   new session uses the expected SHA, Codex command and sandbox settings.
5. When sessions tied to the prior release have exited and the canary passes,
   retire the instructions mounts and their boot units. Remove retired
   `instructions_root` entries and rollout environment overrides. Verify all
   profiles after restart, then restore the saved desired states.

If recovery is necessary, pause and drain before restoring the prior release
and its matching operator configuration. Preserve live control databases,
assignment owners, workspaces and evidence. The deploy script restores the
previous binary drop-in automatically after a failed health check. Restore
separately changed configuration from the deployment backup.

## Initial migration from legacy services

| Profile | Legacy unit | Effective workflow below `/opt/apps/symphony` | Cap | Legacy control |
| --- | --- | --- | ---: | --- |
| FE | `symphony-fe.service` | `runtime/repos/signapse-ui/WORKFLOW.md` | 2 | FE database |
| BE | `symphony.service` | `runtime/repos/signapse/WORKFLOW.md` | 1 | Shared BE/Landing database |
| QA | `symphony-qa.service` | `runtime/repos/signapse-qa/WORKFLOW.md` | 2 | QA database |
| Landing | `symphony-landing.service` | `runtime/repos/signapse-landing/WORKFLOW.md` | 1 | Shared BE/Landing database |
| Planning | `symphony-planning.service` | `runtime/ops/planning-canary-20261022/WORKFLOW.md` | 1 | Planning canary database |

Derive each deployment workflow from the effective file. In particular, carry
the FE and BE local caps, QA's effective wrapper and sandbox, Landing's
repository/browser wrapper, and Planning's standalone canary and Story filter.
The release manifest has separate control paths and published upstreams and a
shared assignment owner database outside every workspace. Keep existing workspaces
and task branches, QA's durable
evidence, account pool and locks, and provider credentials with the same grants.
Install the FE and QA prepare hooks at their stable paths. Resolve credentials
from protected systemd environment files by name; do not put values in the
manifest, checkout, runbook, or deploy log. Preserve per-profile PATH and
Git/Codex configuration explicitly.

Copy [the FE hook](../ops/grouped/prepare-fe-workspace) and
[the QA hook](../ops/grouped/prepare-qa-workspace) to `runtime/` with mode
`0750`. Export the reviewed revision with `git archive` when staging from
Windows to preserve the Linux shebangs. Save the previous executables with
the rollback inputs. The FE hook copies the existing private app environment
to the assignment workspace with mode `0600`. The QA hook checks the pinned
revision through the installed consumer checker while preserving the
assignment's durable `artifacts` link.
Keep the existing QA runtime README, Playwright MCP wrapper, account pool,
browser cache and locks installed.

Start from [profiles.json.example](../ops/grouped/profiles.json.example), the
[user unit](../ops/grouped/symphony-grouped.service), and
[sys.config.example](../ops/grouped/sys.config.example). Place the manifest,
`service.env`, and Phoenix `sys.config` in `runtime/grouped`. Copy the
effective workflows into `runtime/grouped/workflows/<profile>.md`, setting
`runtime_control.path: $CONTROL_DB`, `id: <profile>`, and
`members: [<profile>]` in each. Keep `workspace.root: $SYMPHONY_WORKSPACE_ROOT`.
The operator supplies the environment aliases in the manifest from the
existing protected sources. Preserve the live Jira API base URL for the shared
owner store, and supply the direct site URL for display links.
Copy only the names granted to each profile. In particular, FE needs the app
environment path, optional E2E environment path and integration lock. QA needs
its private directory, recovery root and browser cache. Landing needs its
browser wrapper and cache, host-platform override and public preview flags.
For an optional variable absent in the effective service, remove that alias
from its manifest entry. An unresolved alias makes the profile unavailable.

Replace the example hostname in both the endpoint URL and allowed origin with
the deployment’s HTTPS hostname. Generate a real Phoenix session secret and
replace the LiveView signing salt in the protected config. The release
`-config` replaces the entire endpoint settings list. Retain the Bandit adapter,
render error formats, PubSub server and LiveView settings in the template.

### Stage configuration before the handoff

Run this from the reviewed Symphony checkout as the service operator. Set
`release_sha` to the integrated commit and `candidate` to its approved
artifact directory. Keep candidate configuration separate until the operator
has compared it with the effective workflows and the active service state.

```sh
app=/opt/apps/symphony
grouped="$app/runtime/grouped"
backup="$candidate/pre-cutover"
install -d -m 0700 "$grouped" "$grouped/workflows" "$backup"
install -m 0600 ops/grouped/profiles.json.example "$candidate/profiles.json"
install -m 0600 ops/grouped/sys.config.example "$candidate/sys.config"
install -m 0750 ops/grouped/prepare-fe-workspace "$candidate/prepare-fe-workspace"
install -m 0750 ops/grouped/prepare-qa-workspace "$candidate/prepare-qa-workspace"
install -m 0644 ops/grouped/symphony-grouped.service "$candidate/symphony-grouped.service"
install -m 0644 ops/grouped/AGENTS.md "$candidate/AGENTS.md"
install -m 0750 "$app/runtime/prepare-fe-workspace" "$backup/prepare-fe-workspace"
install -m 0750 "$app/runtime/prepare-qa-workspace" "$backup/prepare-qa-workspace"
install -m 0644 "$app/AGENTS.md" "$backup/AGENTS.md"
```

Resolve manifest aliases through the protected candidate `service.env`.
Systemd already provides `HOME`, `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS` to the user unit. Leave credentials and profile
path values in the protected source. Verify every `$NAME` in each entry can
resolve when the service starts, including the FE app environment and the
QA private/recovery paths. Use systemd’s `EnvironmentFile` parser.

After review, install the manifest, Phoenix config and protected environment
file into `runtime/grouped`. Install the reviewed per-profile deployment
workflows into `runtime/grouped/workflows`. Then build the release and staged
drop-in without changing the legacy units:

```sh
install -m 0600 "$candidate/profiles.json" "$grouped/profiles.json"
install -m 0600 "$candidate/sys.config" "$grouped/sys.config"
install -m 0600 "$candidate/service.env" "$grouped/service.env"
for profile in fe be qa landing planning; do
  install -m 0600 "$candidate/workflows/$profile.md" "$grouped/workflows/$profile.md"
done
python3 scripts/deploy_symphony.py --prepare-grouped "$release_sha" "$candidate"
sha256sum "$candidate/grouped-90-cd.conf" "$grouped/profiles.json" "$grouped"/workflows/*.md
```

Before changing ownership, archive the verified legacy binary and source SHA,
unit files and drop-ins, Serve mapping, effective workflows, control database
backups, and the workspaces/session identities needed to reconcile active work.
Record the operator's desired state for every profile before applying a
maintenance pause. Confirm active turns and contained sessions are gone and
reconcile any pending external writes. A dashboard that says paused can still
track an assignment, so a paused label alone does not prove drain.

After stopping all five legacy units, split the drained control state into
five databases, keeping retries with their original profile. Verify original
ownership from Jira and recorded workspace/session identities; seed the
assignment owner store before enabling admission. Ambiguous ownership or an
unconfirmed process stop blocks cutover. Do not move or delete workspaces as
part of the topology change. Preserve the operator's latest state separately
from maintenance pauses and startup errors. The staging command creates five
paused databases for the first grouped start, including Planning.

Once the legacy runtimes are inactive and the staged databases are verified,
install the reviewed hooks, unit and drop-in as the service operator:

```sh
units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
install -m 0750 "$candidate/prepare-fe-workspace" "$app/runtime/prepare-fe-workspace"
install -m 0750 "$candidate/prepare-qa-workspace" "$app/runtime/prepare-qa-workspace"
install -m 0644 "$candidate/AGENTS.md" "$app/AGENTS.md"
install -d -m 0700 "$units/symphony-grouped.service.d"
install -m 0644 "$candidate/symphony-grouped.service" "$units/symphony-grouped.service"
install -m 0600 "$candidate/grouped-90-cd.conf" "$units/symphony-grouped.service.d/90-cd.conf"
systemctl --user daemon-reload
systemctl --user start symphony-grouped.service
```

Confirm all five legacy units are inactive and the grouped service has one
MainPID. Check that all five profile state endpoints report healthy, paused,
the expected cap and `instructions_source: "checkout"`. Verify the dashboard
through HTTPS 443 and its `/live` WebSocket using the configured HTTPS origin.
After these checks, use each profile's own Resume action for profiles recorded
as running. Confirm the quota check passed and leave the profiles recorded as
paused in that state. Record any canary authorization separately. Remove only
the old Symphony HTTPS ports 4000–4004 from Serve once 443 is verified. Keep
the 443 proxy to loopback port 4000 and the 5432/8443 mappings. Recheck after
restart.

Before changing Serve, capture `tailscale serve status --json` and compare
each path and proxy target to the rehearsal. For each verified legacy
HTTPS mapping, remove it with `tailscale serve --https=PORT off` for
4000–4004 only. Rollback uses `tailscale serve --bg --https=PORT TARGET`
with the corresponding saved target. Do not reset Serve globally.

The automated deploy script skips until the operator creates
`runtime/grouped/cutover-complete` after those checks. Before creating the
marker, confirm the nightly from the reviewed main revision passed its native
Linux x86-64 smoke test and contains the expected OTP version receipt. The
deploy workflow checks that receipt and the artifact checksum before it
connects to the host. Deployment requires all legacy units inactive, changes
only `symphony-grouped.service`, and restores its previous drop-in and binary
if any profile's health fails. Remove the marker under the deployment lock
before rolling back topology. Keep an authenticated operator session for the
entire handoff.

Rollback reverses the ownership handoff: record latest desired states, drain
the grouped runtime, reconcile writes/sessions, stop it, and restore the legacy
hooks, deployment-root `AGENTS.md`, units and Serve mappings. Seed the legacy
control databases with the latest per-profile retry and desired state. BE and
Landing must use separate control files and single-member workflow settings
on rollback. Pointing both
back at their shared database loses independent pause intent. The old
workspace roots and assignment ownership remain authoritative.

To rehearse the SQLite split on copies, build an inventory with
`tracker_base_url`, `project_key`, `assignments` (rows with `issue_id`
and `profile_id`), and `profiles` (one object per profile with `source`,
`workspace_root`, and `desired` containing mode, reason, source, and changed_at).
Run `python3 scripts/stage_symphony_state.py inventory.json NEW_DIRECTORY`.
The command checks drained control state and matches every recorded retry to
an assignment owner before writing the staged files. Inspect the staged rows
and confirm all five modes are paused before installing any candidate database.
For rollback, after confirming the grouped process is inactive, add
`--restore-desired` and supply the latest inventory captured before the rollback
maintenance pause. The resulting per-profile databases seed the split legacy
units. Keep the assignment owner database for future cutovers.
