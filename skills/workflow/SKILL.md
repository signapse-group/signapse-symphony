---
name: workflow
description: Load and apply the shared planning, execution, review, issue, and delivery policy for repositories that explicitly adopt Agent Workflow. Use when a repository AGENTS.md selects this plugin or the user explicitly asks to apply it.
---

# Agent Workflow

Apply this workflow only when the working repository's `AGENTS.md` explicitly adopts Agent Workflow, or when the user explicitly asks to apply it for the current scope. Installation alone does not adopt the workflow.

Read [references/workflow.md](references/workflow.md) before workflow-dependent action. Then read the repository-root `AGENTS.md` for repository roles, GitHub Project identity, build and test commands, delivery condition, coding standards, and domain-document locations. Repository instructions take precedence for project-specific facts; the shared policy remains authoritative for workflow behavior unless the user explicitly changes it.

Adoption does not require a plugin version in `AGENTS.md`. If the installed workflow requires project-specific configuration that the repository has not declared, report the missing configuration before the dependent action and continue independent work that remains valid. Do not rewrite the repository's adoption declaration to follow routine plugin upgrades.

Load references only when the task needs them:

- Business analysis and requirement quality: [references/business-analysis.md](references/business-analysis.md)
- GitHub Issues, Project, and PR metadata: [references/issue-tracker.md](references/issue-tracker.md)
- Epic, Story, Task, and Bug formats: [references/issue-types](references/issue-types)
- Material decisions during execution: [references/decision-gate.md](references/decision-gate.md)
- Cross-repository API delivery: [references/api-handoff.md](references/api-handoff.md)
- Domain language and ADRs: [references/domain.md](references/domain.md)

This entrypoint reads policy and project configuration. It does not itself authorize issue publication, implementation, PR creation, merge, or deployment.
