# Story format

A Story describes one observable stakeholder outcome inside an Epic. Human owners assess its value and completion.

## Required body

```markdown
## Outcome
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

## Dependencies and References
- ...

## Open Decisions
- Material unresolved decisions only.
```

Acceptance Criteria describe observable behavior and meaningful exceptions. They must be clear enough to verify without prescribing routine implementation. Split Stories by stakeholder outcome, not technical layer. Do not create child Tasks until enough information exists for durable work contracts.
