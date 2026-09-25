---
name: setup-workflow
description: Configure Symphony execution for assigned work by creating or updating WORKFLOW.md from verified repository, tracker, and deployment facts.
---

# Setup Workflow

Run this skill explicitly when configuring or refreshing Symphony execution for a repository.
Invoking `$setup-workflow` establishes that the repository will run assigned work through Symphony;
do not ask the user to confirm that choice again. This is a repository onboarding workflow, not
Symphony host installation, implementation, planning, or issue publication. Read existing
`AGENTS.md` for context if present, but do not create or edit it. The only file this skill writes is
`WORKFLOW.md`.

## Explore first

Read [agent-execution-policy](../agent-execution-policy/SKILL.md) and its shared policy before
drafting or refreshing the Symphony prompt. Reading the policy for configuration does not start an
implementation run. Compare existing instructions with the policy; an old repository rule is not
an exception merely because it is already written. Preserve only explicit current repository
exceptions in `WORKFLOW.md`. If a material exception is unclear, ask about that exception.

Inspect the target repository before proposing any configuration:

- `AGENTS.md`, `CLAUDE.md`, `WORKFLOW.md`, and any existing Agent Workflow, Symphony, or agent-skills sections, as read-only sources except for `WORKFLOW.md`;
- `git remote -v` and `.git/config` for repository identity and hosting;
- package/build configuration and existing scripts for focused checks and completion checks;
- CI workflow files for required CI;
- existing issue, contract, architecture, API, and domain-document locations;
- repository-specific delivery conventions and human acceptance ownership when documented;
- the tracker adapter and scope, dispatch/active/terminal states, repository bootstrap, and how
  project-scoped skills remain available after the repository is cloned;
- the deployed Symphony profile or an existing workflow for deployment-owned settings such as
  workspace location, polling, concurrency, Codex command, approval, and sandbox policy.

For Symphony workspace paths, inspect the deployed runtime environment and service configuration in
addition to repository files. `workspace.root` is normally a deployment-level setting, not a
repository-specific input. If an existing workflow uses an environment-backed value such as
`$SYMPHONY_WORKSPACE_ROOT`, treat that reference as the verified configuration and preserve it;
do not ask the user to re-enter the resolved server path.

Treat the shared policy's `In progress`, `Blocked`, `In review`, and `Done` labels as semantic
roles, not tracker configuration values. Read the exact provider-native names from the target
board and map each role explicitly. Never substitute familiar Linear or GitHub state names.

For a GitHub Projects v2 board using the standard Agent Workflow profile, start with this mapping
and verify each option against the board's `Status` field before drafting:

- `Open`: outside autonomous dispatch;
- `Ready`: dispatch and initial active state;
- `In progress`: active implementation state;
- `In review`: non-terminal human handoff state;
- `Blocked`: external-input wait state, outside active execution;
- `Done`: terminal state.

Generate `dispatch_states: [Ready]`, `active_states: [Ready, In progress]`,
`review_state: In review`, and `terminal_states: [Done]`. Ask for a mapping override only when the
board does not expose one of these exact options. Do not inspect application code to infer this
mapping.

The default Project issue filter is `issue_types: [Task, Bug]`. Verify that both `Task` and `Bug`
occur in the target Project's Issue `issueType.name` values before writing the workflow. If either
type is absent, stop the draft at that setting and ask for the intended issue types; do not silently
dispatch a broader set. A Project with no matching items is not evidence that the type exists.

Verify the mapping through the configured tracker connector or GitHub Projects API. When `gh` is
available, `gh project field-list <number> --owner <owner> --format json` is the preferred read-only
check. Repository source code is not evidence for the target board's live options.

Verify issue types with the Project GraphQL item query used by the GitHub adapter and collect every
`Issue.issueType.name` across all pages. The check passes only when both `Task` and `Bug` are present.

For GitHub Projects, verify that the Project's `Item closed` workflow is enabled before describing
issue closure as an automatic transition to `Done`. Report an unverified or disabled workflow as a
delivery configuration gap; do not present the status mapping alone as proof of automation.

Use evidence from the repository, tracker, and deployed Symphony profile. Do not invent repository
names, issue URLs, Project IDs, commands, CI requirements, delivery conditions, or named owners.
Infer routine bootstrap from committed package-manager and lock files, and use role-based ownership
such as repository maintainers or PR reviewers when repository policy establishes that role without
naming a person. Ask only for a material repository or tracker decision that cannot be discovered
and would change dispatch or delivery behavior.

## Configuration boundary

Configure only the project-specific execution context needed by the Symphony entrypoint:

- repository role and contract source;
- focused and completion checks;
- required CI;
- delivery condition and any exceptions to the shared issue-linking rule;
- human acceptance owner;
- relevant architecture, API-contract, and domain-context locations;
- output language.

Map existing tracker fields and states into the runtime configuration. Do not design or publish product requirements, Epic/Story/Task/Bug bodies, issue-tracker schemas, planning workflow, Project fields, triage labels, or domain terminology. Those belong to the planning repository or the consuming repository's own policy.

Keep these ownership boundaries explicit:

- The repository owns tracker scope, issue filters, repository bootstrap, required skills, checks,
  delivery policy, and the unattended prompt.
- The Symphony deployment owns workspace location, polling, concurrency, Codex command, model,
  approval policy, sandbox policy, credentials, and host tool availability.

Preserve or inherit deployment-owned values from the deployed profile. Keep environment-backed
references such as `$SYMPHONY_WORKSPACE_ROOT` instead of resolving them into machine-specific paths.
Do not ask the repository user to choose deployment settings during repository onboarding. If the
deployment profile cannot be inspected, retain existing references and values; for absent optional
fields, rely on supported runtime defaults and report the deployment verification gap. Do not invent
host-specific values merely to make the draft look complete.

The generic execution policy remains in `$agent-execution-policy` and its bundled references. Keep
the Symphony prompt short and store only facts specific to the consuming repository. Do not copy
the shared policy into `WORKFLOW.md`. Put the project-specific execution facts collected above in
its prompt, or point to stable repository sources for them; do not rely on an `AGENTS.md` adoption
block. Do not require `AGENTS.md` to run assigned work.

## Draft before writing

Summarize what was found, what is missing, and any assumptions. Read
[references/symphony-workflow.md](references/symphony-workflow.md) and show the complete proposed
`WORKFLOW.md`. Its prompt must load `$agent-execution-policy`, invoke `$implement` for the
assigned work item, and state the granted lifecycle actions and handoff boundary. Keep credentials
in environment variables or an existing external credential helper.

Before showing the `WORKFLOW.md`, summarize the proposed mapping as `dispatch`, `active`,
`review handoff`, and `terminal`. The review handoff must be non-terminal and excluded from
`active_states` when Symphony should stop while a human owns the next action.

Ask the user to accept or edit the `WORKFLOW.md` draft before writing. Do not infer acceptance from silence.
Do not ask whether Symphony is used, whether ordinary lockfile-based dependency installation is
allowed, or which deployment defaults to use. If a material repository or tracker setting remains
unknown, ask only about that setting and keep independently verified settings in the draft. Do not
write a `WORKFLOW.md` with placeholders that would make Symphony invalid or dispatch the wrong work.

## Write safely

After explicit acceptance:

1. Create or update the root `WORKFLOW.md`. Preserve valid provider-specific and deployment-owned
   settings and unrelated prompt instructions unless they conflict with the accepted execution
   boundary. Never copy credentials into it.
2. Confirm that the cloned Symphony workspace can discover `$agent-execution-policy`, `$implement`, and their required companion skills. Prefer project-scoped installed skills committed with the repository; otherwise record the verified worker provisioning mechanism.
3. Do not overwrite unrelated edits or create or change `AGENTS.md`.

Re-read the resulting `WORKFLOW.md` and report its exact path, the settings written, unresolved items,
and any repository or deployment evidence gap. Validate its YAML. The accepted `WORKFLOW.md` prompt
grants only the unattended actions it states; it does not implicitly authorize merge or deployment.
