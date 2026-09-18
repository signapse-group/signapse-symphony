---
name: to-ticket
description: Publish or reconcile agreed work as GitHub issues when the user requests issue creation or restructuring.
---

# To Ticket

Turn agreed input into durable work contracts. This skill owns issue publication and decomposition, not implementation or the choice of implementation tools.

An explicit request to publish or restructure issues authorizes the corresponding writes. Do not require another approval of the whole tree. Ask only when a new material decision is needed; a recommendation, assumption, or unanswered question is not an accepted requirement. A request merely to review or plan ticket creation does not authorize publication.

## Read the Sources

Read the supplied brief and any source issue's full body, comments, parent, children, and dependencies. Use repository-qualified URLs; a bare number needs an unambiguous repository from context. Inspect relevant code and domain documentation only when needed to establish facts.

Require repository adoption and load [workflow](../workflow/SKILL.md). Read the shared [issue-tracker policy](../workflow/references/issue-tracker.md) plus the repository's `AGENTS.md` for repository targets, Project, permissions, ownership, and delivery rules. Do not inherit legacy labels, automatic work selection, or closure conventions.

Read the selected type's core sections and template before drafting. Use the shared [issue-tracker policy](../workflow/references/issue-tracker.md) and consult type guidance only when needed:

- [Epic](../workflow/references/issue-types/epic.vi.md): a capability or large outcome requiring multiple Stories.
- [Story](../workflow/references/issue-types/story.vi.md): one observable stakeholder outcome.
- [Task](../workflow/references/issue-types/task.vi.md): a concrete deliverable with a valid completion boundary.
- [Bug](../workflow/references/issue-types/bug.vi.md): actual behavior deviating from an established expected behavior and basis.

For work spanning producer and consumer repositories, also read [API handoff](../workflow/references/api-handoff.md). These documents own the body formats; do not maintain duplicate templates here. Preserve the source language unless the user requests another language.

## Preflight and Reconciliation

Before any write:

1. Resolve the configured repositories and Project by owner/number. Verify access to the repositories involved, native issue types, required Project fields/options, and usable CLI capabilities. Never select a Project by an approximate title or silently fall back to another repository.
2. Search existing issues in repositories relevant to the requested scope, including closed candidates. Expand across repositories when parent, dependency or contract links require it. Read candidate bodies and relationships; titles alone do not establish identity or duplication.
3. Reuse the source issue as root when its repository and scope are appropriate. If it cannot remain the root in the correct repository, present the concrete transfer/restructuring question before proceeding with that branch; do not silently transfer it or create a duplicate root.
4. Build an internal publication plan mapping every requirement and accepted decision to a root/child, repository, title, body, parent, dependency, and intended readiness. Check coverage and dependency cycles before publishing.

Apply the shared [business analysis guidance](../workflow/references/business-analysis.md) in this check: requirement quality, alignment with accepted needs and impact on related contracts when reconciling. Preserve criterion-level traceability using the selected templates.

Before publication, run a contract-quality pass:

- Map every Epic High-Level Requirement and Success Criterion to one or more Stories; report uncovered or multiply-owned requirements.
- Give each Story one observable stakeholder outcome and a vertical verification boundary. Do not split Stories by backend/frontend, database, API, or other technical layer.
- Ensure each Story separates Acceptance Criteria, Business Rules, and Quality & Constraints. Acceptance Criteria must cover the successful outcome and meaningful exceptions; add authorization, privacy, lifecycle, concurrency, idempotency, or data-integrity cases when applicable.
- Keep accepted domain rules and constraints in the parent or Story that owns them. Do not invent values, states, metrics, endpoints, or policies to fill a template.
- Create child Tasks only when the Story has enough contract detail for an independently verifiable deliverable. A broad or unresolved Story remains Open with the missing contract recorded.
- Check scope boundaries and dependencies for overlap, omission, and cycles before publishing.

Use current native `gh` commands where supported. Always pass the target repository explicitly. Use Project owner/number and resolve IDs at runtime when needed; do not hardcode opaque IDs. Missing access or required native functionality must be reported, not replaced with labels or duplicate relationship lists in the body.

## Classify and Decompose

- Reuse/retype the source root according to scope: Epic, Story, Task, or Bug. Without a source issue, create the appropriate root in the configured repository.
- Use Epic -> Story -> Task/Bug when the scope warrants it. Standalone technical work and bugs do not need artificial parents. Do not create a Sub-task type.
- Create enough Stories to represent the known Epic scope. Create execution children only for branches with sufficient requirements, accepted technical decisions, verification, and valid deliverables. Report unready branches without inventing their implementation.
- Prefer the Epic/Story structure as a set of user-visible vertical capabilities. Carry shared requirements to the parent and keep child-specific behavior in the owning Story; do not repeat the entire Epic in every child.
- Separate BE and FE Tasks when each has its own deliverable. Include necessary validation and automated checks in the behavior Task; do not split solely by file, layer, or test type.
- Prefix backend Task/Bug titles with `BE:` and frontend Task/Bug titles with `FE:`. Do not invent a surface for work that belongs to neither. Epic/Story stay in the configured planning repository, execution issues in their code repositories.
- Default to one FE UI-plus-integration Task blocked by the BE API Task when a new API is required. Split UI from integration only if UI can land as a valid deliverable on its own; integration then depends on both UI and BE. Mocking does not satisfy the live integration dependency.
- Keep shared decisions at the appropriate parent or linked source. Preserve Task-specific decisions in the Task and map its Requirement Coverage to relevant Story criteria. Do not copy the entire parent into each child.
- Render the selected type's body faithfully, omit unused optional sections and placeholders, and preserve accepted scope, rationale, and verification requirements. Keep workflow tools, branches, and PR lifecycle instructions out of issue bodies.

Human owns work contracts. Do not extend an active or completed issue to absorb a different outcome. Changes to an active contract require the user's accepted decision; changed boundaries follow the replacement policy. New requirements for completed work need new issues. Preserve existing human content and comments when reconciling.

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
