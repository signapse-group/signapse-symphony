# Story format

A Story describes one observable stakeholder outcome inside an Epic. Human owners assess its value and completion.

## Required body

```markdown
## User Story / Outcome
As <stakeholder>, I can <capability>, so that <value>.

## Context and Basis
Accepted need, relevant current behavior, and source references.

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

## Dependencies and References
- Parent Story/Epic, prerequisite capabilities, and relevant references.

## Open Decisions
- Material unresolved decisions only.
```

Acceptance Criteria describe observable behavior and meaningful exceptions. They must be clear enough to verify without prescribing routine implementation. Include failure, authorization, lifecycle, privacy, concurrency, idempotency, or data-integrity cases when the outcome depends on them. Keep stable invariants in Business Rules and non-functional obligations in Quality & Constraints instead of hiding them in prose. Split Stories by stakeholder outcome, not technical layer. A Story should be a vertical capability with a valid stakeholder verification boundary. Do not create child Tasks until enough information exists for durable work contracts.
