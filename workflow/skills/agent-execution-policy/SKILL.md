---
name: agent-execution-policy
description: Load and apply the shared implementation, verification, review, and delivery policy for repositories that explicitly adopt these skills.
---

# Agent Execution Policy

Apply this workflow only when the working repository's `AGENTS.md` explicitly adopts it, or when the user explicitly asks to apply it for the current scope. Installing the skills does not adopt the workflow.

Read [references/execution-policy.md](references/execution-policy.md) before workflow-dependent action. Then read the repository-root `AGENTS.md` for repository role, contract source, build and test commands, required CI, delivery condition, coding standards, and relevant documentation locations. Repository instructions take precedence for project-specific facts; the shared policy remains authoritative for workflow behavior unless the user explicitly changes it.

Adoption does not require a skill version in `AGENTS.md`. If required project-specific configuration is missing, report it before dependent action and continue independent work that remains valid. Do not rewrite the repository's adoption declaration during routine skill updates.

Load [references/decision-gate.md](references/decision-gate.md) only when execution reaches an unresolved material decision. Load [references/api-handoff.md](references/api-handoff.md) only for producer/consumer API delivery.

This entrypoint reads policy and project configuration. It does not itself authorize implementation, remote writes, merge, or deployment.
