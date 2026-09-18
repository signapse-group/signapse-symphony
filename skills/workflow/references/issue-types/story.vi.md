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
