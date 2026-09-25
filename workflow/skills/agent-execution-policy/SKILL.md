---
name: agent-execution-policy
description: Load the shared implementation, verification, review, and delivery policy for an explicitly assigned workflow run.
---

# Agent Execution Policy

Apply this workflow only when the Symphony prompt assigns work and loads this skill, or when the user explicitly requests this workflow for the current scope. Installing the skills or finding repository instructions does not activate the workflow.

Read [references/execution-policy.md](references/execution-policy.md) before workflow-dependent action. Use the assigned prompt, repository files, tracker, and existing `AGENTS.md` if present for project-specific facts. Repository instructions take precedence for project-specific facts; the shared policy remains authoritative for workflow behavior unless the user explicitly changes it.

If required project-specific configuration is missing, report it before dependent action and continue independent work that remains valid. Do not create or edit `AGENTS.md` merely to activate this workflow.

Load [references/decision-gate.md](references/decision-gate.md) only when execution reaches an unresolved material decision. Load [references/api-handoff.md](references/api-handoff.md) only for producer/consumer API delivery.

This entrypoint reads policy and project configuration. It does not itself authorize implementation, remote writes, merge, or deployment.
