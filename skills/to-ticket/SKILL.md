---
name: to-ticket
description: Publish or reconcile agreed work as GitHub issues when the user requests issue creation or restructuring.
---

# To Ticket

Publish and reconcile already-defined work contracts. Session synthesis, issue decomposition, and draft bodies belong to `to-spec`; this skill owns GitHub publication and verification.

This is an issue-first flow. Record requirements, accepted decisions, scope, and verification boundaries in the owning issue. Do not create or update ADRs, context files, or other architecture documents while publishing or normalizing issues unless the user explicitly requests that documentation or the repository's policy names it as a required deliverable. A technical choice that is routine, reversible, or needed only to implement a Task remains in the Task or with the implementer.

An explicit request to publish or restructure issues authorizes the corresponding writes. Do not require another approval of the whole tree. Ask only when a new material decision is needed; a recommendation, assumption, or unanswered question is not an accepted requirement. A request merely to review or plan ticket creation does not authorize publication.

## Read the Sources

Read the supplied issue plan and draft bodies, and any source issue's full body, comments, parent, children, and dependencies. Use repository-qualified URLs; a bare number needs an unambiguous repository from context. Inspect relevant code and domain documentation only when needed to establish facts.

Require repository adoption and load [workflow](../workflow/SKILL.md). Read the shared [issue-tracker policy](../workflow/references/issue-tracker.md) plus the repository's `AGENTS.md` for repository targets, Project, permissions, ownership, and delivery rules. Do not inherit legacy labels, automatic work selection, or closure conventions.

Read the selected type's core sections and template before drafting. Use the shared [issue-tracker policy](../workflow/references/issue-tracker.md) and consult type guidance only when needed:

- [Epic](../workflow/references/issue-types/epic.md): a capability or large outcome requiring multiple Stories.
- [Story](../workflow/references/issue-types/story.md): one observable stakeholder outcome.
- [Task](../workflow/references/issue-types/task.md): a concrete deliverable with a valid completion boundary.
- [Bug](../workflow/references/issue-types/bug.md): actual behavior deviating from an established expected behavior and basis.

For work spanning producer and consumer repositories, also read [API handoff](../workflow/references/api-handoff.md). These documents own the body formats; do not maintain duplicate templates here. Preserve the source language unless the user requests another language.

## Input Boundary

Accept a readable issue plan from `to-spec` or equivalent explicit input that already defines the issue boundaries, types, bodies, repositories, and relationships. A fully defined single issue is sufficient; do not force a separate spec step when the input already supplies the contract.

If input is only a conversation, broad brief, or restructuring goal that still requires synthesis or decomposition, report the specific missing definition and direct the user to `to-spec`. Do not silently perform that work or invoke the explicit-only skill. Continue independently publishable parts only when already authorized. Publication authorization does not turn new proposals or unresolved decisions into accepted requirements.

## Preflight and Reconciliation

Before any write:

1. Resolve the configured repositories and Project by owner/number. Verify access to the repositories involved, native issue types, required Project fields/options, and usable CLI capabilities. Never select a Project by an approximate title or silently fall back to another repository.
2. Search existing issues in repositories relevant to the requested scope, including closed candidates. Expand across repositories when parent, dependency or contract links require it. Read candidate bodies and relationships; titles alone do not establish identity or duplication.
3. Reuse the source issue as root when its repository and scope are appropriate. If it cannot remain the root in the correct repository, present the concrete transfer/restructuring question before proceeding with that branch; do not silently transfer it or create a duplicate root.
4. Map the supplied draft keys to existing or new issues, repositories, native parents/dependencies, and intended readiness. Check coverage, overlaps, and dependency cycles against the supplied plan. Resolve live IDs and URLs; do not redesign deliverable boundaries. Report material conflicts or missing contracts for definition before writing the affected branch.

Verify the supplied bodies against the selected type templates and accepted scope. Preserve requirement coverage, accepted decisions, rationale, and verification requirements. Mechanical formatting and link resolution belong here; new requirements, changed boundaries, or substantive contract rewrites return to definition. Keep native relationships outside issue bodies and preserve concurrent human content.

Use current native `gh` commands where supported. Always pass the target repository explicitly. Use Project owner/number and resolve IDs at runtime when needed; do not hardcode opaque IDs. Missing access or required native functionality must be reported, not replaced with labels or duplicate relationship lists in the body.

## API Contract Comment

For a BE API/FE integration pair, create or reuse one `API Contract` comment on the BE Task from the contract already agreed in the input. Include the externally observable behavior, request/response, authorization, business rules, errors, and examples that are known. Never invent endpoints, schemas, or deployed versions.

Link the exact comment URL from FE References. Mark it as a planning contract pending implementation and dev handoff; it is not evidence that the API is deployed. If the agreed contract is insufficient, record the missing decision and do not mark the FE integration Task Ready. The BE Task may still be Ready if its own work contract is sufficient.

Before creating or updating a comment, read the existing comments and reuse only the matching, unfinalized contract. Do not edit a contract frozen by BE completion. Later API changes require a new Task/comment linked to the prior handoff. The BE implementer refines the comment before PR review; human confirms the deployed commit/version in a reply at Done. Do not fabricate that reply or delivery evidence.

## Publish in Recoverable Steps

Use native `gh issue create/edit` type, parent, and dependency options when available. Pass Markdown through a UTF-8 temporary body file using `--body-file`; never interpolate body content into shell code. Temporary transport files are not a second issue store.

Publish parents and blockers before their dependents, recording returned URLs immediately. Reconcile in this order:

1. Root and Story bodies/types.
2. Task/Bug bodies/types in dependency order.
3. Native parent and blocking relationships, using full URLs across repositories.
4. API contract comments and FE reference links when applicable.
5. Project membership and readiness fields.

Read back each recoverable group before dependent operations or reporting success; one read may verify multiple completed mutations. Verify bodies/types, relationships, comments/references and Project fields as applicable. A successful create alone proves none of the later updates. Uncertain creates must be reconciled before any retry.

For retries, start from the source root and recorded URLs, compare actual bodies/types/relationships, and perform only missing or intended changes. On an uncertain create response, inspect the repository before retrying. If identity cannot be established, report the ambiguity rather than create again. Do not identify an issue solely by a matching title.

If publication partially fails, retain the created issues and verified URLs. Report completed and pending operations; do not delete issues to roll back or loop indefinitely on the same failure. Re-read an issue before overwriting its body if it may have changed since planning; preserve concurrent human edits and resolve conflicting contract changes.

Potential duplicates are reported to the human. Reuse an existing issue only when its identity and intended role are clear; do not close an issue as duplicate or not planned unless the human has already made that decision.

## Readiness and Ownership

New items enter the configured Project as Open. After body, type, parent, dependencies, and required references are verified, move sufficiently clear Task/Bug items from Open to Ready. An unresolved material contract stays Open with the gap explained. Routine implementation details delegated by repository standards, including seam selection, do not prevent Ready. Ready means clear enough to plan, not permission to start; an outstanding execution dependency may coexist with Ready.

On reruns, preserve existing Ready, In progress, Blocked, In review, Done, and closed states unless an explicit accepted change calls for a transition. Do not reset active/completed work or automatically mark it Ready. Existing Epic/Story Status belongs to the human; initial Open membership is not authority to manage their lifecycle.

Do not assign work, start implementation, create PRs, change global Project configuration, or invoke a downstream workflow. Do not use labels, Sprint, Severity, or Priority fields in this flow.

## Report the Result

Return a concise tree or table with verified issue URLs, types, repositories, parent/dependency links, and Status. Include contract-comment URLs, reused issues, remaining Open branches and their gaps, potential duplicates, and incomplete operations when present. Distinguish verified publication from planned or failed operations. Do not claim the whole tree is Ready when only some branches are ready.
