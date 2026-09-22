# Agent Workflow skills repository instructions

This repository develops a reusable collection of Codex skills for implementation, verification, review, and delivery. Keep the skills free of product identity, credentials, opaque GitHub IDs, absolute author-machine paths, and application-specific build commands.

Use `skills/agent-execution-policy/references/execution-policy.md` as the shared operational policy. Keep project-specific adoption data in the consuming repository's `AGENTS.md` and Symphony runtime configuration in its `WORKFLOW.md`. Installation alone must not activate project lifecycle behavior.

Planning, requirement definition, issue authoring, and issue publication belong to the planning repository or another upstream process. These skills consume an assigned issue or accepted local contract; they do not create or decompose product requirements.

When changing a skill, preserve its invocation policy unless the change explicitly requires another mode. Keep `implement` and `setup-workflow` explicit-only. Resolve skill resources relative to the installed skill and consuming-repository resources from its working tree.

Validate changed skills with the bundled skill validator and run `tests/validate_package.py`. For documentation-only edits, these checks are sufficient.
