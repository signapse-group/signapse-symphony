---
name: to-spec
description: Summarize the session and define a readable spec with issue decomposition and draft contracts, without publication.
---

# To Spec

Own session synthesis, issue decomposition, and draft work contracts. Produce a user-readable spec from the conversation and established evidence. Preserve the user's latest accepted decisions, meaningful identifiers, references and rationale. Inspect code or domain docs only for relevant facts not already established.

Keep requirements traceable to accepted needs or verified constraints. Distinguish assumptions and proposals from decisions; omit superseded options unless their rationale matters. Do not add requirements to fill a template or silently resolve conflicts.

Require repository adoption and load [workflow](../workflow/SKILL.md). Apply the shared [business analysis guidance](../workflow/references/business-analysis.md) when checking requirement quality and alignment with the accepted need. Preserve established need evidence, outcome assumptions and evaluation methods in the brief; surface material gaps under Open Questions.

## Content and Precision

Include the desired outcome, sufficient scope and observable acceptance, accepted technical/testing decisions, exclusions and known work boundaries where established. Use user stories only when an actor helps. Avoid repeating the same requirement under several headings.

For a bug, preserve expected behavior and basis, actual behavior, impact, reproduction/observation, evidence, fix scope and verification requirements.

Source paths or short snippets are useful when they make a decision precise; identify them as current evidence or an accepted contract shape, not a permanent implementation prescription. Preserve prototype decisions without copying a demo.

Separate consequential unresolved decisions under Open Questions from routine implementation details left to the implementing agent. A seam that can be chosen under repository standards is not a missing human decision or a readiness blocker. Record established verification requirements without inventing a test approach.

For a broad brief that benefits from a scaffold, consult [brief-template.md](brief-template.md). It is optional; use only sections that carry distinct information.

## Define the Issues

Read the selected type guidance and template before drafting: [Epic](../workflow/references/issue-types/epic.md), [Story](../workflow/references/issue-types/story.md), [Task](../workflow/references/issue-types/task.md), or [Bug](../workflow/references/issue-types/bug.md). These references own body formats; do not duplicate templates. For producer/consumer work, also read [API handoff](../workflow/references/api-handoff.md).

Map accepted requirements and decisions to proposed issues with local draft keys, types, titles, target repositories, parents, dependencies, and readiness with reasons. Keep this relationship map outside issue bodies; local keys are planning references, not fabricated GitHub IDs or URLs. A single standalone issue is a valid plan. Mark missing repository mappings as gaps instead of guessing; live GitHub access is not required to synthesize established context.

When restructuring existing issues, read supplied issues and relevant comments/relationships when accessible. Preserve their identities and human content; disclose unavailable evidence and distinguish proposed changes from verified current state. Publication will recheck live state and duplicates.

## Classify and Decompose

- Reuse/retype the source root according to scope: Epic, Story, Task, or Bug. Without a source issue, draft the appropriate root for the configured repository.
- Use Epic -> Story -> Task/Bug when the scope warrants it. Standalone technical work and bugs do not need artificial parents. Do not create a Sub-task type.
- Draft enough Stories to represent the known Epic scope. Draft execution children only for branches with sufficient requirements, accepted technical decisions, verification, and valid deliverables. Report unready branches without inventing their implementation.
- Prefer the Epic/Story structure as a set of user-visible vertical capabilities. Carry shared requirements to the parent and keep child-specific behavior in the owning Story; do not repeat the entire Epic in every child.
- Separate BE and FE Tasks when each has its own deliverable. Include necessary validation and automated checks in the behavior Task; do not split solely by file, layer, or test type.
- Do not infer a BE or FE Task merely because a Story mentions the server, client, API, or UI. Create a surface-specific Task only when that surface has an independently deliverable and verifiable contribution to the Story outcome.
- Prefix backend Task/Bug titles with `BE:` and frontend Task/Bug titles with `FE:`. Do not invent a surface for work that belongs to neither. Epic/Story stay in the configured planning repository, execution issues in their code repositories.
- Default to one FE UI-plus-integration Task blocked by the BE API Task when a new API is required. Split UI from integration only if UI can land as a valid deliverable on its own; integration then depends on both UI and BE. Mocking does not satisfy the live integration dependency.
- Keep shared decisions at the appropriate parent or linked source. Preserve Task-specific decisions in the Task and map its Requirement Coverage to relevant Story criteria. Do not copy the entire parent into each child.
- Render the selected type's body faithfully, omit unused optional sections and placeholders, and preserve accepted scope, rationale, and verification requirements. Do not repeat native parent, sub-issue, or dependency relationships in issue bodies. In Stories, keep necessary rationale or external references beside the contract term they support instead of adding generic context or reference sections; retain the reference sections defined for other issue types.
- Include `Open Decisions` only when material decisions remain unresolved. When reconciling a resolved decision, incorporate its durable result into the owning contract section and remove the resolved item; remove the section when it becomes empty.
- Keep workflow tools, branches, and PR lifecycle instructions out of issue bodies.

Human owns work contracts. Do not extend an active or completed issue to absorb a different outcome. Changes to an active contract require the user's accepted decision; changed boundaries follow the replacement policy. New requirements for completed work need new issues. Preserve existing human content and comments when reconciling.

Before returning the spec, run a contract-quality pass:

- Map every Epic High-Level Requirement and Success Criterion to one or more Stories; report uncovered or multiply-owned requirements.
- Give each Story one observable stakeholder outcome and a vertical verification boundary. Do not split Stories by backend/frontend, database, API, or other technical layer.
- Apply the Story boundary checks from the selected type guidance. Identify the usage situation, stakeholder goal, and acceptance boundary; test whether a coherent subset could be prioritized, deferred, or accepted independently while retaining meaningful value. Split only when that reveals a distinct outcome, not by CRUD operation, screen, endpoint, or a fixed criterion count. Briefly explain consequential grouping or separation choices in the issue map.
- Distinguish cross-cutting rules and quality concerns from stakeholder outcomes. Keep shared rules at the parent or authoritative reference and put observable applications in the Stories they govern unless the concern has its own outcome and acceptance boundary.
- Resolve acceptance-significant terms such as "valid", "supported", "appropriate", and "consistent" through an explicit rule or precise reference. Surface a missing material definition as an Open Decision instead of inventing it. Check related Stories for conflicting ownership or behavior.
- Run an implementation-leakage pass on every Story. Do not make a team, layer, service, endpoint, framework, or database the subject of a Story requirement. Rewrite those statements as an externally verifiable outcome, business rule, or quality constraint. Keep a server-side or backend reference only when it expresses a necessary security, privacy, data-integrity, localization, reliability, or compatibility invariant; omit the implementation mechanism and let Tasks choose the seam.
- Ensure each Story separates Acceptance Criteria, Business Rules, and Quality & Constraints. Acceptance Criteria must cover the successful outcome and meaningful exceptions; add authorization, privacy, lifecycle, concurrency, idempotency, or data-integrity cases when applicable.
- Keep accepted domain rules and constraints in the parent or Story that owns them. Do not invent values, states, metrics, endpoints, or policies to fill a template.
- Create child Tasks only when the Story has enough contract detail for an independently verifiable deliverable. A broad or unresolved Story remains Open with the missing contract recorded.
- Check scope boundaries and dependencies for overlap, omission, and cycles before handoff.

For a BE API/FE integration pair, draft the known API Contract comment separately and identify which FE draft will reference it. Preserve accepted behavior, schemas, authorization, errors, and examples without inventing missing details or delivery evidence. The publisher resolves the actual comment URL; unresolved contract gaps affect proposed readiness.

## Completion

Return a readable artifact in chat, not only a completion message or an internal plan. Include:

- A session summary of the need, accepted decisions and rationale, scope, exclusions, and material open questions. Omit superseded discussion unless it explains a durable decision.
- An issue tree or table with draft keys, types, titles, repositories, parents, dependencies, and proposed readiness; explain the chosen deliverable boundaries.
- The full draft body for each proposed issue, using its type template, plus any agreed API Contract comment draft. Keep uncovered requirements and unready branches visible instead of inventing contracts.

Use the optional scaffold to organize the output, and preserve the repository's output language. Draft structure is a proposal; distinguish it from accepted requirements. This output is the handoff to `to-ticket`, which reconciles and publishes it only on explicit request. Do not interview, ask for blanket reconfirmation, create issues, or invoke another skill automatically. Write a spec file only when requested or required by repository policy, and link it from the response; otherwise the complete output stays in chat.
