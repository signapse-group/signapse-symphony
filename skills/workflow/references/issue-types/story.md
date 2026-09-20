# Story format

A Story describes one observable stakeholder outcome inside an Epic. Human owners assess its value and completion.

## Required body

```markdown
## User Story / Outcome
As <stakeholder>, I can <capability>, so that <value>.

## Acceptance Criteria
- AC-1: Given ..., when ..., then ...
- AC-2: ...

## Scope
### In scope
- ...

### Out of scope
- ...

## Business Rules
- Stable domain rules, invariants, state transitions, permissions, or data-contract rules.

## Quality & Constraints
- Security, privacy, reliability, localization, performance, operational, or compatibility constraints that are required for the outcome.
```

Add an `Open Decisions` section only while material decisions remain unresolved. Once a decision is accepted, move its durable result into the relevant outcome, criterion, scope, rule, or constraint and remove the resolved item; omit the section when no open decisions remain.

Do not repeat the native parent, sub-issue, or dependency relationships in the Story body. Place a source or rationale beside the specific outcome, criterion, rule, or constraint it supports when that information is necessary to understand or verify the contract. Do not add a general context section whose content can be discovered from the codebase or parent issue.

Acceptance Criteria describe observable behavior and meaningful exceptions. They must be clear enough to verify without prescribing routine implementation. Include failure, authorization, lifecycle, privacy, concurrency, idempotency, or data-integrity cases when the outcome depends on them. Keep stable invariants in Business Rules and non-functional obligations in Quality & Constraints instead of hiding them in prose. Split Stories by stakeholder outcome, not technical layer. A Story should be a vertical capability with a valid stakeholder verification boundary. Do not create child Tasks until enough information exists for durable work contracts.

For each Story, identify one concrete usage situation, the stakeholder's goal, and the result that can be accepted. Broad verbs such as "manage", "maintain", or "support" do not by themselves establish one outcome. If a coherent group of criteria can be prioritized, deferred, or accepted independently while still delivering meaningful stakeholder value, consider a separate Story. Keep the criteria together when they are jointly necessary to complete the same goal. Do not split mechanically by CRUD operation, screen, endpoint, frontend/backend boundary, or a fixed limit on Acceptance Criteria.

A shared rule or quality concern is a separate Story only when it has its own stakeholder outcome and acceptance boundary. Otherwise, keep the shared rule in the parent or an authoritative reference and place the observable criteria in the Stories whose behavior it governs.

Terms such as "valid", "supported", "appropriate", and "consistent" must be grounded in an explicit rule or a precise authoritative reference when they determine acceptance. Do not invent the missing rule. Record a material unresolved choice as an Open Decision and leave routine implementation detail to the implementing Task.

Check related Stories together for conflicting ownership or behavior, especially lifecycle transitions, permissions, identifiers, and public contracts. A requirement should have one clear owner even when another Story depends on it.

Before publishing, run an implementation-leakage check. A Story must not make a team, layer, service, endpoint, framework, component, or database the actor of the requirement. Rewrite those references as behavior or a verifiable constraint. A server-side or backend reference is appropriate only when it states a required security, privacy, data-integrity, localization, reliability, or compatibility invariant; it must not prescribe the mechanism. For example, prefer “unauthorized requests do not return private note content” over “the backend applies ownership middleware.”
