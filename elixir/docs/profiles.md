# Profile runtime contract

A grouped deployment starts with `symphony --profiles /etc/symphony/profiles.json` and the existing guardrails acknowledgement. The positional workflow argument still starts the single-workflow runtime. The grouped dashboard uses one loopback listener, port 4000 by default. The manifest also specifies an absolute `assignment_owners_path` or a `$HOST_VAR` resolving to that path. Keep this SQLite database outside all workspaces, instruction trees and profile control databases. Preserve it across restarts and migrations so a Jira assignment cannot be claimed by a different profile.

The [five-profile fixture](../test/fixtures/profiles/profiles.json) shows the manifest and per-workflow settings together. The manifest is a JSON object with a `profiles` array. Each entry names `id`, `workflow`, `instructions_root`, `control_path` and `env`. Supported IDs in display order are `fe`, `be`, `qa`, `landing`, `planning`. A test or canary can provide a subset. Relative paths resolve from the manifest directory. The absolute `control_path` can also reference a host variable as `$NAME`. It is available from `Profile.lookup(id)` even when the workflow cannot load, so G2 can persist pause and read desired state using the default control timings. The workflow front matter must name the same DB and a one-member group matching the profile ID. Colliding control paths disable both entries before their DBs can open. Workspace roots come from workflow front matter and resolve relative to the workflow file. Define an explicit workspace root for each profile. Set per-profile PATH, HOME, CODEX_HOME, hooks and wrapper variables explicitly in the manifest. Intentional shared values are set explicitly on each profile. A complete value of the form `$NAME` resolves that named host variable at startup. Use that form for credentials. The manifest and its referenced directories are operator-owned. The runtime resolves canonical workspace/control/instructions paths, which the operator must keep stable while the service runs. The web must never serialize effective settings, credentials or subprocess environment.

## Runtime interfaces

- `Profile.ids/0` lists configured profiles. `Profile.via(id, role)` registers OTP names scoped by profile. The common roles are `:workflow_store`, `:runtime_supervisor`, `:orchestrator`, `:task_supervisor`, and `:runtime_control`. G2 owns runtime names and per-profile log and recovery state; use the profile ID on all session, ownership and recovery keys.
- `WorkflowStore.snapshot(id)` returns `{:ok, snapshot}` or `{:error, reason}`. The snapshot has `profile_id`, `workflow_path`, `instructions_root`, `settings`, `workflow`, `revision` (SHA-256 of deployment workflow bytes), and `env`. Pass it explicitly into callbacks and worker launches. Keep scoped workspace/hook/Codex settings stable for each assignment/session. Read a fresh snapshot before admission or session rollover and let G2 reconcile running/retry ownership.
- `WorkflowStore.status(id)` exposes only the deployment revision and safe error codes. The most recent reload error is separate from the active snapshot. G4 obtains counts and control state from the selected G2 scheduler, and instructions revision from G3. A missing profile or a scoped store starting or failing never falls back to the legacy workflow.
- In grouped runtime control status, `active_turns` counts distinct worker owners holding permits. A single worker can hold an assignment permit and a provider turn permit. Pause waits for both permits to be released. The legacy runtime counts individual permits.
- `Tracker.fetch_issues_by_states(states, snapshot.settings.tracker)` and `Tracker.fetch_issues_by_ids(ids, snapshot.settings.tracker)` accept captured Jira settings. `DynamicTool.bind(snapshot.settings.tracker)` pins the tool adapter and settings for a session. Do not rebind in async callbacks. These arities also accept explicit test doubles via Jira adapter injection; legacy adapters keep their existing calls.
- `Profile.subprocess_env(snapshot, secret_environment_names)` supplies env pairs suitable for `System.cmd`. It clears inherited keys omitted by the manifest and any listed adapter secrets. Convert `nil` values to `false` for `Port.open`. Apply the same boundary to hooks and Codex sessions and avoid login shells in grouped mode so profile variables cannot be overwritten by login scripts.
- Grouped profiles must use one canonical Jira API base URL and project. Credentials may differ. Assignment filters must select Jira native Story in Planned (Planning) or native Subtask with the required recognized route for that profile. Routed profiles must recognize each other's route so a mixed-label Subtask cannot match both. Workspaces, instructions roots and control DBs cannot overlap, including through symlinks. The first valid workspace/filter reservation remains active and a later conflicting candidate stays unavailable. Once a profile has a valid reservation, changes to its filter or root require drain, reconciliation and restart. Normal reload retains the active snapshot and records an update error.

## Instructions package

The operator stages an immutable package at `<instructions_root>/revisions/<revision>/`, preserving the consumer-relative paths (including the workflow's original location when applicable). A checked package contains an `instructions.json` manifest, workflow, AGENTS and the full closure of required standards, runbooks, skills and local references. Manifest fields are:

```json
{
  "profile_id": "fe",
  "revision": "consumer-git-sha-or-other-immutable-id",
  "workflow": "WORKFLOW.md",
  "required_files": ["AGENTS.md", "CONTRIBUTING.md", "workflow/implement.md"]
}
```

An `active` text file at `instructions_root` contains the chosen revision. G3 owns atomic validation and activation, including renderer preflight, path containment and protection of an already-active revision from candidate changes. `Profile.lookup(id)` gives G3 the canonical instructions root resolved at startup. The deployment workflow owns service settings and hooks; the pinned local instructions workflow supplies the session prompt. Revision identifiers and paths are checked before opening a session. Session prompt Liquid variables are `profile.id`, `instructions.revision` and `instructions.root`, and the runtime prompt identifies these values even if the consumer template does not use them.

G3 supplies `Instructions.pin(id)` and `Instructions.activate(id, revision)`. A pin returns `{:ok, %{profile_id: id, revision: revision, root: root, workflow_path: path, workflow: parsed}}` or a readiness error. G2 keeps that value through a session and passes it explicitly to PromptBuilder. G4 posts activation to the selected ID with an explicit candidate revision. Failed validation leaves the previous revision active. Reading disk candidate files does not switch an existing pin.

While a profile is healthy, its scheduler revalidates the active package on the first poll after one minute and checks sooner when the active revision changes or a new session starts. The runtime detects changes to the files in the validated package under the same active revision and blocks new admission for that profile. Restore the original package or activate a different revision. The first validation after a scheduler restart trusts the operator-staged package, so protect revision directories from writes at the host as well as inside the worker.

To stage a package using the source checkout and grouped deployment manifest, run the Mix task from `elixir/`:

```bash
SYMPHONY_PROFILES=/etc/symphony/profiles.json \
  mix instructions.prepare fe <consumer-commit> /opt/apps/symphony/runtime/repos/signapse-ui \
    WORKFLOW.md CONTRIBUTING.md
```

The task resolves the commit locally, copies the workflow, `AGENTS.md`, the listed files and their instruction references, and reports the staged revision. Pass every required file named only in prose, including scoped instructions when required. For a workflow stored at a nested path, give that original repository-relative path, for example `workflow/symphony/WORKFLOW.md` for Planning. The task never updates the consumer checkout. Its source must already have the selected commit and files available.

Use `SYMPHONY_PROFILES=/etc/symphony/profiles.json mix instructions.validate <profile> <package-dir>` to check a separately staged package. Preflight runs the same Solid renderer used at session start for every configured phase and each QA operation. Links resolve from their source document and local Markdown anchors are checked. Use ordinary inline Markdown links for instructions. Mark attribution and historical links with a `Provenance:` link label. Required steps and references must be packaged locally.

The package must be readable to the worker. Stage files with read permissions and no write bits, and protect the `revisions/` tree from worker writes using host permissions or a read-only mount. The runtime needs permission to replace the adjacent `active` file. Keep previous revisions available while any session uses them. Use the selected profile's dashboard action to activate a staged revision. Operator staging can run from a deployment checkout separate from the running workers.

Grouped workspace hooks run in the assignment workspace with the scoped environment. For a pinned run, hooks can read `SYMPHONY_INSTRUCTIONS_ROOT`, `SYMPHONY_INSTRUCTIONS_REVISION`, and `SYMPHONY_PROFILE_ID`. In QA, point the existing local checker at the pinned root while the prepare hook manages durable evidence in the assignment workspace.

## Existing global callers

| Owner | Existing callers and boundary |
| --- | --- |
| G1 | Application and CLI startup, Workflow, WorkflowStore, Config and Schema, Jira adapter and client, Tracker and DynamicTool. Legacy GitHub, GitLab, Asana, Linear and memory adapter calls remain single-workflow. |
| G2 | AgentRuntimeSupervisor, Orchestrator, RuntimeControl, AgentRunner, Codex AppServer and SessionProcess, and SSH session configuration. Thread the profile and captured settings through dispatch, reconciliation, retry, async tracker tasks, task-supervisor callbacks and cleanup. Process/session resources and desired state must be profile scoped. |
| G3 | Workspace, PromptBuilder, WorkflowUpdate and the workspace cleanup Mix task. Scope hooks, path handling and shell environment. Run the local renderer/validator and pin immutable instructions per session. |
| G4 | HttpServer, Phoenix Endpoint, DashboardLive, controller, Presenter, ObservabilityPubSub and terminal StatusDashboard. Select the profile per request, scope observability notifications, and build responses only from safe projections. |
| G10 | Deploy manifest, consumer local overrides, control DB paths/memberships, host env and process/snapshot permissions. Preserve the live worker cap and wrapper/sandbox settings. |
