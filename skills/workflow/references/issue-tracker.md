# GitHub issue and Project operations

Read this reference only for GitHub issue, Project, PR metadata, or lifecycle operations. The shared [workflow](workflow.md) owns authority and status semantics. The adopting repository's `AGENTS.md` owns repository mapping, Project owner/number, delivery condition, required CI, and acceptance owner.

Use current native `gh` capabilities where available and pass repository targets explicitly. Resolve opaque IDs at runtime. Verify authentication, repository access, issue types, relationships, Project fields/options, and required CI before relying on them. Missing access or native functionality is a blocker for the dependent mutation, not permission to emulate it with labels or body text.

Use native Issue Types `Epic`, `Story`, `Task`, and `Bug` when configured. Use native parent/sub-issue and blocking relationships. Do not add labels, Sprint, Severity, Priority, or other fields unless the adopting repository explicitly configures them.

For writes, place exact Markdown in a UTF-8 temporary body file and use `--body-file`. Publish parents and blockers before dependents. Record returned URLs immediately, read back each recoverable group, and verify body/type, relationships, contract comments, Project membership, and Status. On uncertain creation, inspect before retrying. Never identify an issue only by title.

New items enter the configured initial status, normally Open. Move a Task/Bug to Ready only after its body, type, parent, dependencies, and required references are verified and no material contract decision remains. Preserve active and completed states on reconciliation unless an accepted change requires a transition. Epic and Story lifecycle remains human-owned.

Partial failure keeps verified created items and reports completed and pending operations. Do not delete issues as rollback. Preserve concurrent human edits. Potential duplicates require human disposition unless an accepted decision already identifies the duplicate or replacement.
