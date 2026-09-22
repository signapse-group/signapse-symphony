---
name: setup-workflow
description: Configure a repository to adopt the Agent Workflow execution skills and, when applicable, run them through Symphony by updating AGENTS.md and WORKFLOW.md from verified repository facts.
---

# Setup Workflow

Run this skill explicitly once when a repository is adopting the Agent Workflow execution skills, adding Symphony orchestration, or refreshing either configuration. This is a configuration workflow, not an implementation, planning, or issue-publication workflow.

## Explore first

Inspect the target repository before proposing any configuration:

- `AGENTS.md`, `CLAUDE.md`, `WORKFLOW.md`, and any existing Agent Workflow, Symphony, or agent-skills sections;
- `git remote -v` and `.git/config` for repository identity and hosting;
- package/build configuration and existing scripts for focused checks and completion checks;
- CI workflow files for required CI;
- existing issue, contract, architecture, API, and domain-document locations;
- repository-specific delivery conventions and human acceptance ownership when documented;
- for Symphony, its tracker adapter and scope, dispatch/active/terminal states, workspace bootstrap, worker environment, and how project-scoped skills remain available after the repository is cloned.

Use evidence from the repository. Do not invent repository names, issue URLs, Project IDs, commands, CI requirements, delivery conditions, or owners. Mark a setting as `To confirm` when the repository does not establish it.

## Configuration boundary

Configure only the project-specific adoption context needed by the execution skills and their Symphony entrypoint:

- repository role and contract source;
- focused and completion checks;
- required CI;
- delivery condition and issue-linking rule;
- human acceptance owner;
- relevant architecture, API-contract, and domain-context locations;
- output language.

When Symphony is used, map existing tracker fields and states into its runtime configuration. Do not design or publish product requirements, Epic/Story/Task/Bug bodies, issue-tracker schemas, planning workflow, Project fields, triage labels, or domain terminology. Those belong to the planning repository or the consuming repository's own policy.

The generic execution policy remains in `$agent-execution-policy` and its bundled references. Keep `AGENTS.md` and the Symphony prompt short and store only facts specific to the consuming repository. Do not copy the shared policy into either file.

## Draft before writing

Summarize what was found, what is missing, and any assumptions. Then show the complete proposed `AGENTS.md` block before changing a file:

```markdown
## Agent Workflow

This repository adopts the Agent Workflow execution skills.
At the start of each new session, read `$agent-execution-policy` before workflow-dependent action.
`WORKFLOW.md` is the Symphony runtime entrypoint for assigned work; repository instructions remain here.

- Repository role and contract source: ...
- Focused and completion checks: ...
- Required CI: ...
- Delivery condition and issue-linking rule: ...
- Human acceptance owner: ...
- Relevant architecture and contract locations: ...
- Output language: ...
```

When Symphony is being configured, read [references/symphony-workflow.md](references/symphony-workflow.md) and also show the complete proposed `WORKFLOW.md`. Its prompt must load `$agent-execution-policy`, invoke `$implement` for the assigned work item, and state the granted lifecycle actions and handoff boundary. Keep credentials in environment variables or an existing external credential helper.

Ask the user to accept or edit both drafts before writing. Do not infer acceptance from silence. If a material setting remains unknown, ask only about that setting and keep independently verified settings in the draft. Do not write a `WORKFLOW.md` with placeholders that would make Symphony invalid or dispatch the wrong work.

## Write safely

After explicit acceptance:

1. Prefer the repository's existing `AGENTS.md` as the instruction source.
2. If `AGENTS.md` does not exist, report that the workflow requires a root adoption file and ask whether to create it. Do not silently choose `CLAUDE.md` or create both files.
3. If an `## Agent Workflow` block exists, update that block in place and preserve surrounding user content.
4. Otherwise, append the accepted block with the repository's existing line-ending and language conventions.
5. When Symphony is configured, create or update the root `WORKFLOW.md`. Preserve valid provider-specific settings and unrelated prompt instructions unless they conflict with the accepted execution boundary. Never copy credentials into it.
6. Confirm that the cloned Symphony workspace can discover `$agent-execution-policy`, `$implement`, and their required companion skills. Prefer project-scoped installed skills committed with the repository; otherwise record the verified worker provisioning mechanism.
7. Do not overwrite unrelated edits, replace the whole `AGENTS.md`, or create duplicate adoption blocks.

Re-read both resulting files and report their exact paths, the settings written, unresolved items, and any evidence gap. Validate the `WORKFLOW.md` YAML when Symphony is configured. `AGENTS.md` adopts the shared workflow; the accepted `WORKFLOW.md` prompt grants only the unattended actions it states. Neither file implicitly authorizes merge or deployment.
