# Bug format

A Bug records an observed incident or behavior that appears to deviate from an established expectation. The report should make the incident actionable with the information currently available; missing details may be marked `Unknown`, `Not checked`, or `To investigate` and filled in later. Do not invent facts or root causes. Ready does not authorize execution.

## Body template

Use the sections that carry information. The minimum useful report is a concrete symptom, the best available context or incident evidence, and the expected result when it is known. Keep the remaining sections when they help investigation, even if some entries are unknown.

```markdown
## Expected Behavior
Expected observable result, if known. If the requirement or basis is not yet available, write `To confirm` and link the source or investigation question.

**Basis:** Accepted requirement, contract, documentation, prior verified behavior, or `To confirm`.

## Actual Behavior
Observed deviation without root-cause speculation.

## Impact
Known affected stakeholders/workflow and practical consequence. Use `Unknown` when not established yet.

## Reproduction or Observation
### Context
- Environment:
- Actor/role:
- Input/preconditions:

### Steps or incident evidence
1. ...

### Result
- Observed result, occurrence if known, safe identifiers, and evidence limits.

## Regression (optional)
Known last-good evidence, or `Unknown`.

## Fix Scope (optional)
Behavior to restore; avoid unverified implementation prescriptions.

## Verification Requirements (optional at intake)
- Repeat the public repro or equivalent acceptance observation.
- Add appropriate regression evidence at the repository's stable public seam.

## Dependencies and References (optional)
- Story/contract/evidence links.
```

If a current attempt does not reproduce, distinguish the attempt from the incident evidence and record the limits. A report may be opened to investigate a specific, observed symptom even when reproduction, regression history, impact, or expected behavior still needs confirmation; do not publish a report with no concrete observation or supporting evidence. Use native parent/dependency relationships and configured Project fields. Repository routing and title prefixes come from the adopting repository's `AGENTS.md`.
