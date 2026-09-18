# Task format

A Task is one concrete, independently deliverable result with a valid verification boundary. Ready means clear enough to execute; assignment is separate authorization.

## Required body

```markdown
## Objective
Concrete result this Task delivers.

## Requirement Coverage
- Story AC or accepted local contract covered by this Task.

## Deliverable
- Durable output and repository/location.

## Scope
### In scope
- ...

### Out of scope
- ...

## Acceptance Criteria
- Observable behavior or artifact condition.

## Verification
- Stable public seam and required evidence/checks.

## Dependencies and References
- Native blockers, parent, design, or API contract URLs.

## Open Decisions
- Material unresolved decisions only.
```

Do not split Tasks by database/service/controller, file count, or agent step. Keep branch, skill, PR, and status-transition instructions out of the body. Use repository mapping and title prefixes only when the adopting repository requires them. For cross-repository APIs, link the exact producer `API Contract` comment; a planning contract is not delivery evidence.
