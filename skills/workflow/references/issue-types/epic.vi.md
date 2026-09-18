# Epic format

An Epic is a capability or large outcome requiring multiple independently valuable Stories. Human owners define and complete Epics based on outcome evidence.

## Required body

```markdown
## Problem / Opportunity
The user or business problem, why it matters, and the accepted basis.

## Desired Outcome
The observable capability or change that should result.

## Stakeholders and Value
Who benefits or is affected, and what useful change is expected.

## Scope
### In scope
- ...

### Out of scope
- ...

## Success Criteria
- Observable outcome and evidence source.

## High-Level Requirements
- Product or domain behavior required to reach the outcome.

## Shared Constraints and Decisions
- ...

## References
- Relevant domain, product, or existing-behavior references.
```

Add an `Open Decisions` section only while material decisions remain unresolved. Remove resolved items after incorporating their durable results into the relevant contract sections, and omit the section when none remain.

Use a concise capability/outcome title without type prefixes. Keep implementation decomposition in Stories and Tasks. Do not manufacture metrics, dates, child issues, or transition requirements without accepted need. High-Level Requirements must be traceable to one or more Stories; Shared Constraints and Decisions must contain only accepted rules, not speculative implementation. New Epics enter the configured Project state; their later lifecycle remains human-owned.
