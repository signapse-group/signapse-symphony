# Bug format

A Bug records actual behavior that deviates from an established Expected Behavior and Basis. Reproduction or sufficient incident evidence must identify the relevant environment and actor context. Ready does not authorize execution.

## Required body

```markdown
## Expected Behavior
Expected observable result.

**Basis:** Accepted requirement, contract, documentation, or prior verified behavior.

## Actual Behavior
Observed deviation without root-cause speculation.

## Impact
Affected stakeholders/workflow and practical consequence.

## Reproduction or Observation
### Context
- Environment:
- Actor/role:
- Input/preconditions:

### Steps or incident evidence
1. ...

### Result
- Stable terminal behavior, occurrence, safe identifiers, and evidence limits.

## Regression
Known last-good evidence, or `Unknown`.

## Fix Scope
Behavior to restore; avoid unverified implementation prescriptions.

## Verification Requirements
- Repeat the public repro or equivalent acceptance observation.
- Add appropriate regression evidence at the repository's stable public seam.

## Dependencies and References
- Story/contract/evidence links.
```

If a current attempt does not reproduce but incident evidence is sufficient, distinguish the two. If neither establishes a deviation, do not publish a speculative Bug. Use native parent/dependency relationships and configured Project fields. Repository routing and title prefixes come from the adopting repository's `AGENTS.md`.
