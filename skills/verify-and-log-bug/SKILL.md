---
name: verify-and-log-bug
description: Verify a reported product defect through reproduction or sufficient incident evidence in the requested environment and actor context, then log a workflow-compliant GitHub Bug when authorized. Do not use for root-cause diagnosis or implementation.
---

# Verify and Log Bug

Require repository adoption and load [workflow](../workflow/SKILL.md). Apply the shared [business analysis guidance](../workflow/references/business-analysis.md), [issue tracker policy](../workflow/references/issue-tracker.md), [Bug format](../workflow/references/issue-types/bug.md), and the repository's `AGENTS.md`. Stop before diagnosis, source inspection, instrumentation, or a fix unless separately requested.

## Establish the test contract

Gather the environment, actor role/account, trigger, observable symptom, valid input constraints, Expected Behavior and its accepted Basis, and likely owning Story when they are available. Do not substitute another environment or assume the active account. Record only a non-secret actor identifier when repeatability requires it; mark unavailable context for follow-up.

If Expected Behavior or its accepted Basis is not yet available, record it as `To confirm` and preserve the requirement gap for follow-up; do not manufacture a fact or silently block recording a concrete incident.

## Reproduce without diagnosing

Use the smallest user-level path that exercises the report. For workflows that create or store data, separately verify input acceptance, terminal submission outcome, and persistence/readback. A preview, loading state, or transient message is not a final verdict.

Use benign test data and mark created records as test artifacts. Obtain any confirmation required by the active user request, repository policy, or environment before submissions, uploads, deletions, or other external mutations. Do not delete test artifacts unless authorized; report artifacts left behind. Preserve observable facts: environment, actor, supported input, steps, occurrence, terminal state, and safe record identifiers. Do not include secrets or unsanitized telemetry. If the first run passes, try only a small number of contract-relevant variants.

## Evidence gate

Create a Bug when a concrete symptom is supported by reproduction or sufficiently specific incident evidence. Capture the requested environment, actor, input, expected behavior, repeatability, and impact when available; mark unknown items for follow-up instead of requiring them at intake. Do not create a report with only a vague concern or an ungrounded hypothesis, and search for duplicates before creation.

When incident evidence is sufficient but the current run does not reproduce, distinguish the incident from this session's attempted reproduction and state evidence limits. If neither source provides a concrete observation, report what was tested and do not create a speculative Bug.

## Route and publish

Use the repository mapping, Project identity, native Issue Type, parent rules, and initial Status declared by the adopting repository's `AGENTS.md`. Never guess repository ownership from a user-visible symptom. Search relevant configured repositories before creation.

An explicit request to log the verified defect authorizes issue creation within that scope. It does not authorize changing the Story contract, assigning implementation, diagnosing the cause, or marking the Bug ready for execution.

Follow the canonical [Bug format](../workflow/references/issue-types/bug.md). Preserve known Expected Behavior and Basis, Actual Behavior, Impact, Reproduction or Observation, and follow-up needs. Mark unavailable details explicitly and keep the body free of unverified root-cause claims. Use native relationships and Project fields; do not invent labels or optional fields absent from the adopted workflow.

After creation, verify the issue URL, Type, Project membership, initial Status, and parent relationship when applicable. Return the verified links, evidence summary, and any test artifacts left behind.
