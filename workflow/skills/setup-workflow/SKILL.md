---
name: setup-workflow
description: Configure a repository to adopt the Agent Workflow execution skills by inspecting its local conventions, drafting project-specific settings, and updating AGENTS.md after explicit confirmation.
---

# Setup Workflow

Run this skill explicitly once when a repository is adopting the Agent Workflow execution skills or when its execution configuration needs to be refreshed. This is a configuration workflow, not an implementation, planning, or issue-publication workflow.

## Explore first

Inspect the target repository before proposing any configuration:

- `AGENTS.md`, `CLAUDE.md`, and any existing Agent Workflow or agent-skills sections;
- `git remote -v` and `.git/config` for repository identity and hosting;
- package/build configuration and existing scripts for focused checks and completion checks;
- CI workflow files for required CI;
- existing issue, contract, architecture, API, and domain-document locations;
- repository-specific delivery conventions and human acceptance ownership when documented.

Use evidence from the repository. Do not invent repository names, issue URLs, Project IDs, commands, CI requirements, delivery conditions, or owners. Mark a setting as `To confirm` when the repository does not establish it.

## Configuration boundary

Configure only the project-specific adoption context needed by the execution skills:

- repository role and contract source;
- focused and completion checks;
- required CI;
- delivery condition and issue-linking rule;
- human acceptance owner;
- relevant architecture, API-contract, and domain-context locations;
- output language.

Do not configure or publish product requirements, Epic/Story/Task/Bug bodies, issue-tracker schemas, planning workflow, Project fields, triage labels, or domain terminology. Those belong to the planning repository or the consuming repository's own policy.

The generic execution policy remains in `$workflow` and its bundled references. Keep the repository block short and store only facts that are specific to this repository.

## Draft before writing

Summarize what was found, what is missing, and any assumptions. Then show the complete proposed block before changing a file:

```markdown
## Agent Workflow

This repository adopts the Agent Workflow execution skills.
At the start of each new session, read `$workflow` before workflow-dependent action.

- Repository role and contract source: ...
- Focused and completion checks: ...
- Required CI: ...
- Delivery condition and issue-linking rule: ...
- Human acceptance owner: ...
- Relevant architecture and contract locations: ...
- Output language: ...
```

Ask the user to accept or edit the draft before writing. Do not infer acceptance from silence. If a material setting remains unknown, ask only about that setting and keep independently verified settings in the draft.

## Write safely

After explicit acceptance:

1. Prefer the repository's existing `AGENTS.md` as the instruction source.
2. If `AGENTS.md` does not exist, report that the workflow requires a root adoption file and ask whether to create it. Do not silently choose `CLAUDE.md` or create both files.
3. If an `## Agent Workflow` block exists, update that block in place and preserve surrounding user content.
4. Otherwise, append the accepted block with the repository's existing line-ending and language conventions.
5. Do not overwrite unrelated edits, replace the whole file, or create duplicate blocks.

Re-read the resulting file and report the exact path, the settings written, unresolved `To confirm` items, and any evidence gap. Updating `AGENTS.md` adopts the workflow for future sessions; it does not authorize implementation, issue writes, PR creation, merge, or deployment.
