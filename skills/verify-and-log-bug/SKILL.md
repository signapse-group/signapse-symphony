---
name: verify-and-log-bug
description: Verify a reported product defect through reproduction or sufficient incident evidence in the requested environment and actor context, then log a workflow-compliant GitHub Bug when authorized. Do not use for root-cause diagnosis or implementation.
---

# Verify and Log Bug

Require repository adoption and load [workflow](../workflow/SKILL.md). Apply the shared [business analysis guidance](../workflow/references/business-analysis.md), [issue tracker policy](../workflow/references/issue-tracker.md), [Bug format](../workflow/references/issue-types/bug.vi.md), and the repository's `AGENTS.md`. Stop before diagnosis, source inspection, instrumentation, or a fix unless separately requested.

## Establish the test contract

Resolve the exact environment, actor role/account, trigger, observable symptom, valid input constraints, Expected Behavior and its accepted Basis, and likely owning Story. Do not substitute another environment or assume the active account. Record only a non-secret actor identifier when repeatability requires it.

If Expected Behavior lacks an accepted Basis, report the requirement gap rather than manufacture a Bug contract.

## Reproduce without diagnosing

Use the smallest user-level path that exercises the report. For workflows that create or store data, separately verify input acceptance, terminal submission outcome, and persistence/readback. A preview, loading state, or transient message is not a final verdict.

Use benign test data and mark created records as test artifacts. Obtain any confirmation required by the active user request, repository policy, or environment before submissions, uploads, deletions, or other external mutations. Do not delete test artifacts unless authorized; report artifacts left behind. Preserve observable facts: environment, actor, supported input, steps, occurrence, terminal state, and safe record identifiers. Do not include secrets or unsanitized telemetry. If the first run passes, try only a small number of contract-relevant variants.

## Evidence gate

Create a Bug only when reproduction or incident evidence identifies the requested environment and actor, the input satisfies the contract, Actual Behavior differs from Expected Behavior under equivalent conditions, the result is stable enough to investigate, the observation is repeatable or sufficiently specific, and duplicate search finds no matching issue.

When incident evidence is sufficient but the current run does not reproduce, distinguish the incident from this session's attempted reproduction and state evidence limits. If neither source establishes a deviation, report what was tested and do not create a speculative Bug.

## Route and publish

Use the repository mapping, Project identity, native Issue Type, parent rules, and initial Status declared by the adopting repository's `AGENTS.md`. Never guess repository ownership from a user-visible symptom. Search relevant configured repositories before creation.

An explicit request to log the verified defect authorizes issue creation within that scope. It does not authorize changing the Story contract, assigning implementation, diagnosing the cause, or marking the Bug ready for execution.

Follow the canonical [Bug format](../workflow/references/issue-types/bug.vi.md). Preserve Expected Behavior with Basis, Actual Behavior, Impact, Reproduction or Observation, Fix Scope, and Verification Requirements. Keep the body free of unverified root-cause claims. Use native relationships and Project fields; do not invent labels or optional fields absent from the adopted workflow.

After creation, verify the issue URL, Type, Project membership, initial Status, and parent relationship when applicable. Return the verified links, evidence summary, and any test artifacts left behind.
