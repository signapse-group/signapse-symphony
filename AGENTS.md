# Agent Workflow repository instructions

This repository develops the `agent-workflow` Codex plugin. Keep the plugin reusable across repositories and free of product identity, credentials, opaque GitHub IDs, absolute author-machine paths, and application-specific build commands.

Use `skills/workflow/references/workflow.md` as the shared operational policy. Keep project-specific adoption data in the consuming repository's `AGENTS.md`. Installation alone must not activate project lifecycle behavior.

When changing a skill, preserve its invocation policy unless the change explicitly requires another mode. Keep `implement`, `to-spec`, `to-ticket`, and `grill-with-docs` explicit-only. Resolve plugin resources relative to the installed skill and consuming-repository resources from its working tree.

Validate changed skills with the bundled skill validator, validate the full plugin with the bundled plugin validator, and run `tests/validate_package.py`. For documentation-only edits, these checks are sufficient.
