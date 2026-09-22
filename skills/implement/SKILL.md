---
name: implement
description: Execute assigned work from its issue or accepted contract through implementation, independent review, and a PR ready for human review.
---

# Implement

Require repository adoption and load the shared policy through [workflow](../workflow/SKILL.md), then use the repository-root `AGENTS.md` for project facts. Read the [decision gate](../workflow/references/decision-gate.md) or [API handoff](../workflow/references/api-handoff.md) only when the work needs them. Reuse current context instead of rereading unchanged sources.

Completion means the delivered PR revision satisfies required checks, independent review on both axes and required CI, with only the specified human acceptance remaining. Continue through fixes to that boundary. Authorization comes from the user's request and repository policy. A request only to diagnose or review does not authorize implementation. Do not select unassigned work merely because it is available.

## Ground and Plan

Read the current issue body, decision comments, relevant parent/references, and dependencies. Use exact repository-qualified identities. If the user explicitly assigned an accepted local contract without an issue, work from that contract; do not invent or publish an issue as a prerequisite. Apply issue lifecycle actions only when an issue exists.

Inspect the checkout, branch, target branch, existing PR and dirty files. Reuse the Task's branch/worktree and PR on resume; otherwise isolate work on a scoped branch/worktree as needed. Never commit or overwrite unrelated changes. Resolve the review base to a commit from the intended target branch, and record it in the session so the reviewer can reproduce the scope.

Confirm dependencies are fulfilled before dependent execution. Announce a short plan describing changes, verification seams and material risks, then proceed within accepted scope without a plan-approval round. Do not require a plan file, snapshot, fingerprint or verification report in the repository.

## Implement and Verify

Use [tdd](../tdd/SKILL.md) for behavior verification; choose the highest stable public seam using the issue, repository policy and existing code. Follow the repository's diagnostic workflow when investigation is needed. Keep each slice small, run focused checks and fix failures caused by the change.

Run the completion checks required by repository policy for the affected work. Preserve required public contract documentation and handoff evidence. Missing mandatory evidence is a blocker, not a risk note that automatically permits handoff. Do not require manual live acceptance unless the user or repository policy requests it.

## Decisions and Resume

Follow the repository's decision policy. Investigate discoverable facts first. Raise a material unresolved decision promptly; pause its dependent work while continuing meaningful independent work. Resolve human identities from explicit configuration or user context, never guess whom to mention. If a required durable update is unavailable or not authorized, present the decision in chat and report the missing update.

For assigned issue execution, maintain In progress; use Blocked only when the documented conditions hold. Do not alter parent lifecycle or silently broaden the work contract.

Reread the issue on resume and before handoff. Evidence-only updates do not stop work. Accepted requirement changes within the same deliverable update the plan and invalidate affected checks/review. An unaccepted change or different deliverable requires a decision before dependent work continues. Keep the same branch/PR for review fixes within the original boundary.

## Independent Review

Invoke [code-review](../code-review/SKILL.md) with the issue/contract, resolved base, path ownership, working state and check evidence. It uses one independent reviewer for both axes. Do not substitute the implementing agent's own assessment if independent review is unavailable; report that requirement as unmet.

Resolve blocking findings, rerun affected checks, and have the reviewer reassess fixes and adjacent risks. Challenge an incorrect finding with evidence; escalate only unresolved material disagreement. Optional improvements do not expand the Task.

## PR and CI Handoff

Commit only scoped, reviewed work, push the Task branch and create/update its one PR. Read existing remote state before retrying a mutation to avoid duplicate PRs/comments. Include the source issue/contract, concise acceptance-to-evidence summary, commands/results, both review axes, remaining nonblocking findings, and the verified implementation commit. A later PR-body edit does not create a new code revision.

Follow the repository's issue-linking, contract handoff, merge and lifecycle rules. Do not claim a human-owned acceptance or deployment transition.

Wait for required CI for the current PR revision. Fix in-scope failures on the same branch/PR, rerun affected checks and review, and update evidence after pushing. Do not use a green run from an earlier revision. External failures or missing access must be reported without claiming readiness or relaxing required checks.

Hand off only after required checks and both review axes are satisfied for the delivered code. Apply the repository's handoff lifecycle transition then. When an orchestrator owns lifecycle mutations or CI evidence, use its provided interface and report outcomes rather than competing with it; do not create a second execution record in the checkout.

Return the PR, scope delivered, verification/review result and concrete remaining human acceptance. A narrow standalone invocation stops at the user's requested boundary rather than implicitly publishing.
