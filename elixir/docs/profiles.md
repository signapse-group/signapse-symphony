# Profile runtime contract

A grouped deployment starts with `symphony --profiles /etc/symphony/profiles.json` and the existing guardrails acknowledgement. The positional workflow argument still starts the single-workflow runtime. The grouped dashboard uses one loopback listener, port 4000 by default. The manifest also specifies an absolute `assignment_owners_path` or a `$HOST_VAR` resolving to that path. Keep this SQLite database outside all workspaces and profile control databases. Preserve it across restarts and migrations so a Jira assignment cannot be claimed by a different profile.

The [five-profile fixture](../test/fixtures/profiles/profiles.json) shows the manifest and per-workflow settings together. The manifest is a JSON object with a `profiles` array. Each entry names `id`, `workflow`, `checkout_workflow`, `checkout_upstream`, `control_path`, `env`. Supported IDs in display order are `fe`, `be`, `qa`, `landing`, `planning`. A test or canary can provide a subset. Relative paths resolve from the manifest directory. The absolute `control_path` can also reference a host variable as `$NAME`. It is available from `Profile.lookup(id)` even when the workflow cannot load, so G2 can persist pause and read desired state using the default control timings. The workflow front matter must name the same DB and a one-member group matching the profile ID. Colliding control paths disable both entries before their DBs can open. Workspace roots come from workflow front matter and resolve relative to the workflow file. Define an explicit workspace root for each profile. Set per-profile PATH, HOME, CODEX_HOME, hooks and wrapper variables explicitly in the manifest. Intentional shared values are set explicitly on each profile. A complete value of the form `$NAME` resolves that named host variable at startup. Use that form for credentials. The manifest and its referenced directories are operator-owned. The runtime resolves canonical workspace and control paths, which the operator must keep stable while the service runs. The web must never serialize effective settings, credentials or subprocess environment.

## Checkout instructions

Set `checkout_workflow` to the tracked prompt path relative to the
configured upstream repository. Use `WORKFLOW.md` for FE, BE, Landing,
and QA, or `workflow/symphony/WORKFLOW.md` for Planning. Set
`checkout_upstream` to a GitHub HTTPS `repository` URL without embedded
credentials and a `branch` of `main` or `dev`. QA uses `signapse-qa/main`.

Each worker attempt shallow-clones the current branch tip into a temporary
sparse checkout whose Git SHA is recorded at launch. It supplies Markdown,
skills and supporting scripts. The workspace of the issue remains the
working directory for Git, application files, tests and outputs. A fresh
attempt fetches again without replacing or rebasing that workspace.

Git and GNU `timeout` must be available on the local grouped host. The
clone uses the existing `SYMPHONY_GIT_CREDENTIAL_HELPER` or, when the profile
has a `GITHUB_TOKEN`, `gh auth git-credential`. The worker uses the temporary
checkout with its configured permissions. The recorded SHA identifies the
source at launch. The normal systemd session lifecycle and the configured
Codex and Playwright sandboxes apply.

The operator-owned deployment workflow supplies YAML settings and hooks.
Keep its YAML front matter and delimiters. The consumer workflow contains
only the Markdown/Liquid prompt. After workspace preparation, Symphony
validates and renders that prompt and checks the checkout's `AGENTS.md`,
`.agents/skills`, and required instruction files before starting Codex in
the same workspace. The upstream checkout supplies these files for the attempt.

An invalid checkout pauses only the affected profile. Any active turn can
finish, and new turns and assignments wait for Resume. The pause and the
issue diagnostic survive restart. Restore upstream access or fix the published
files, then use Resume to recheck the source. Configuration issues and transient
workspace failures retain their existing handling.

The grouped observability API reports `instructions_source` as `checkout`.
The deployment workflow revision describes runtime configuration.
Once a task has loaded its prompt, its running record
reports the task checkout HEAD and the SHA-256 of the source workflow
bytes. The load event also records `instructions_head`, the commit from
which those bytes and other instructions were selected.
See the [rollout runbook](../../docs/symphony-grouped-rollout.md) for
preflight, deployment and recovery.

## Runtime interfaces

- `Profile.ids/0` lists configured profiles. `Profile.via(id, role)` registers OTP names scoped by profile. The common roles are `:workflow_store`, `:runtime_supervisor`, `:orchestrator`, `:task_supervisor`, and `:runtime_control`. G2 owns runtime names and per-profile log and recovery state; use the profile ID on all session, ownership and recovery keys.
- `WorkflowStore.snapshot(id)` returns `{:ok, snapshot}` or `{:error, reason}`. The snapshot has `profile_id`, `workflow_path`, `checkout_workflow`, `checkout_upstream`, `settings`, `workflow`, `revision` (SHA-256 of deployment workflow bytes), and `env`. Pass it explicitly into callbacks and worker launches. Keep scoped workspace/hook/Codex settings stable for each assignment/session. Read a fresh snapshot before admission or session rollover and let G2 reconcile running/retry ownership.
- Grouped admission checks the configured Codex account before launching new work or a retry. A continuation checks quota on its existing Codex session before starting the next turn. An exhausted or unavailable quota defers admission while active turns finish and leaves the operator's desired mode intact.
- `WorkflowStore.status(id)` exposes only the deployment revision and safe error codes. The most recent reload error is separate from the active snapshot. G4 obtains counts and control state from the selected G2 scheduler. A missing profile or a scoped store starting or failing never falls back to the legacy workflow.
- In grouped runtime control status, `active_turns` counts distinct worker owners holding permits. A single worker can hold an assignment permit and a provider turn permit. Pause waits for both permits to be released. The legacy runtime counts individual permits.
- Grouped API and dashboard show sessions held for cleanup inspection under Blocked. The session, workspace and last activity remain available in issue details. The scheduler reserves the assignment until it can reconcile the handoff.

- The grouped runtime samples local cgroup memory, swap, pressure and the shared browser lock every five seconds and keeps ten minutes of samples. A local stall is corroborated by a new OOM kill, I/O full PSI at or above 20% of the measured window, or memory some PSI at or above 10% of that window while the cgroup records new high-limit events. Gaps or stale samples over ten seconds, counter resets and remote workers leave pressure unknown. The API exposes the shared lock state to FE and QA without publishing raw host diagnostics.
- Three consecutive heartbeat expiries or stalls corroborated by host pressure pause the affected profile. The threshold retry and pause commit together in the profile's control database. Other profiles continue, and successful resume opens a fresh allowance. Quota deferrals and unclassified stalls do not consume the allowance.
- A failed profile status read returns a safe unavailable status for that profile. The overview retains the other profiles. Retry rows and quota admission show fixed reason codes/messages without raw provider or subprocess responses.
- `Tracker.fetch_issues_by_states(states, snapshot.settings.tracker)` and `Tracker.fetch_issues_by_ids(ids, snapshot.settings.tracker)` accept captured Jira settings. `DynamicTool.bind(snapshot.settings.tracker)` pins the tool adapter and settings for a session. Do not rebind in async callbacks. These arities also accept explicit test doubles via Jira adapter injection; legacy adapters keep their existing calls.
- `Profile.subprocess_env(snapshot, secret_environment_names)` supplies env pairs suitable for `System.cmd`. It clears inherited keys omitted by the manifest and any listed adapter secrets. Convert `nil` values to `false` for `Port.open`. Apply the same boundary to hooks and Codex sessions and avoid login shells in grouped mode so profile variables cannot be overwritten by login scripts.
- Grouped profiles must use one canonical Jira API base URL and project. Credentials may differ. Assignment filters must select Jira native Story in Planned (Planning) or native Subtask with the required recognized route for that profile. Routed profiles must recognize each other's route so a mixed-label Subtask cannot match both. Workspaces and control DBs cannot overlap, including through symlinks. The first valid workspace/filter reservation remains active and a later conflicting candidate stays unavailable. Once a profile has a valid reservation, changes to its filter or root require drain, reconciliation and restart. Normal reload retains the active snapshot and records an update error.

Grouped workspace hooks run in the assignment workspace with the scoped environment. For a pinned run, hooks can read `SYMPHONY_INSTRUCTIONS_ROOT`, `SYMPHONY_INSTRUCTIONS_REVISION`, and `SYMPHONY_PROFILE_ID`. In QA, point the existing local checker at the pinned root while the prepare hook manages durable evidence in the assignment workspace.

## Existing global callers

| Owner | Existing callers and boundary |
| --- | --- |
| G1 | Application and CLI startup, Workflow, WorkflowStore, Config and Schema, Jira adapter and client, Tracker and DynamicTool. Legacy GitHub, GitLab, Asana, Linear and memory adapter calls remain single-workflow. |
| G2 | AgentRuntimeSupervisor, Orchestrator, RuntimeControl, AgentRunner, Codex AppServer and SessionProcess, and SSH session configuration. Thread the profile and captured settings through dispatch, reconciliation, retry, async tracker tasks, task-supervisor callbacks and cleanup. Process/session resources and desired state must be profile scoped. |
| G3 | Workspace, PromptBuilder, WorkflowUpdate and the workspace cleanup Mix task. Scope hooks, path handling and shell environment. Validate and render instructions from the selected upstream checkout per attempt. |
| G4 | HttpServer, Phoenix Endpoint, DashboardLive, controller, Presenter, ObservabilityPubSub and terminal StatusDashboard. Select the profile per request, scope observability notifications, and build responses only from safe projections. |
| G10 | Deploy manifest, consumer local overrides, control DB paths/memberships, host env and process/snapshot permissions. Preserve the live worker cap and wrapper/sandbox settings. |
