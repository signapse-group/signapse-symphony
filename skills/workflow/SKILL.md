---
name: workflow
description: Load and apply the shared planning, execution, review, issue, and delivery policy for repositories that explicitly adopt Agent Workflow. Use when a repository AGENTS.md selects this plugin or the user explicitly asks to apply it.
---

# Agent Workflow

Apply this workflow only when the working repository's `AGENTS.md` explicitly adopts Agent Workflow, or when the user explicitly asks to apply it for the current scope. Installation alone does not adopt the workflow.

Read [references/workflow.md](references/workflow.md) before workflow-dependent action. Then read the repository-root `AGENTS.md` for its verified plugin version, repository roles, GitHub Project identity, build and test commands, delivery condition, coding standards, and domain-document locations. Repository instructions take precedence for project-specific facts; the shared policy remains authoritative for workflow behavior unless the user explicitly changes it.

If the repository requires a different plugin version than the active installation, report the mismatch before workflow-dependent action and continue only independent work that remains valid. Do not silently use the latest version or rewrite the repository's adoption declaration.

Load references only when the task needs them:

- Business analysis and requirement quality: [references/business-analysis.md](references/business-analysis.md)
- GitHub Issues, Project, and PR metadata: [references/issue-tracker.md](references/issue-tracker.md)
- Epic, Story, Task, and Bug formats: [references/issue-types](references/issue-types)
- Material decisions during execution: [references/decision-gate.md](references/decision-gate.md)
- Cross-repository API delivery: [references/api-handoff.md](references/api-handoff.md)
- Domain language and ADRs: [references/domain.md](references/domain.md)

This entrypoint reads policy and project configuration. It does not itself authorize issue publication, implementation, PR creation, merge, or deployment.
