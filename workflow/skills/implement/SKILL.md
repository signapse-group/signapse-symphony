---
name: implement
description: Execute assigned work from its issue or accepted contract through implementation, independent review, and a PR ready for human review.
---

# Implement

Use this skill for implementation requested by a human or assigned by Symphony. The issue lifecycle below applies only when a Symphony prompt or the human explicitly requests the shared workflow. For those runs, load [agent-execution-policy](../agent-execution-policy/SKILL.md) and gather project facts from the prompt and repository sources, including `AGENTS.md` if present. For a standalone human request, implement and verify its scope without imposing issue status, independent review, PR, or CI handoff steps unless requested. Read the [decision gate](../agent-execution-policy/references/decision-gate.md) or [API handoff](../agent-execution-policy/references/api-handoff.md) only when the active workflow needs them. Reuse current context instead of rereading unchanged sources.

For an activated workflow run, completion means the delivered PR revision satisfies required checks, independent review on both axes and required CI, with only the specified human acceptance remaining. Continue through fixes to that boundary. Authorization comes from the user's request and repository policy. A request only to diagnose or review does not authorize implementation. Do not select unassigned work merely because it is available.

## Ground and Plan

Read the current issue body, decision comments, relevant parent/references, and dependencies. Use exact repository-qualified identities. If the user explicitly assigned an accepted local contract without an issue, work from that contract; do not invent or publish an issue as a prerequisite. Apply issue lifecycle actions only when an issue exists.

Inspect the checkout, branch, target branch, existing PR and dirty files. Reuse the Task's branch/worktree and PR on resume; otherwise isolate work on a scoped branch/worktree as needed. Never commit or overwrite unrelated changes. Resolve the review base to a commit from the intended target branch, and record it in the session so the reviewer can reproduce the scope.

Confirm dependencies are fulfilled before dependent execution. Announce a short plan describing changes, verification seams and material risks, then proceed within accepted scope without a plan-approval round. Do not require a plan file, snapshot, fingerprint or verification report in the repository.

## Implement and Verify

Use [tdd](../tdd/SKILL.md) for behavior verification; choose the highest stable public seam using the issue, repository policy and existing code. Follow the repository's diagnostic workflow when investigation is needed. Keep each slice small, run focused checks and fix failures caused by the change.

Run the completion checks required by repository policy for the affected work. Preserve required public contract documentation and handoff evidence. Missing mandatory evidence is a blocker, not a risk note that automatically permits handoff. Do not require manual live acceptance unless the user or repository policy requests it.

## Decisions and Resume

Follow the repository's decision policy. Investigate discoverable facts first. Raise a material unresolved decision promptly; pause its dependent work while continuing meaningful independent work. Resolve human identities from explicit configuration or user context, never guess whom to mention. If a required durable update is unavailable or not authorized, present the decision in chat and report the missing update.

For assigned issue execution, maintain In progress; use Blocked only when the documented conditions hold. For GitHub issues, follow [blocker comments and resume](../agent-execution-policy/references/execution-policy.md#blocker-comments-and-resume) before changing status and when resuming. Do not alter parent lifecycle or silently broaden the work contract.

Reread the issue on resume and before handoff. Evidence-only updates do not stop work. Accepted requirement changes within the same deliverable update the plan and invalidate affected checks/review. An unaccepted change or different deliverable requires a decision before dependent work continues. Keep the same branch/PR for review fixes within the original boundary.

## Independent Review

Invoke [code-review](../code-review/SKILL.md) with the issue/contract, resolved base, path ownership, working state and check evidence. It uses one independent reviewer for both axes. Do not substitute the implementing agent's own assessment if independent review is unavailable; report that requirement as unmet.

Resolve blocking findings, rerun affected checks, and have the reviewer reassess fixes and adjacent risks. Challenge an incorrect finding with evidence; escalate only unresolved material disagreement. Optional improvements do not expand the Task.

## PR and CI Handoff

Commit only scoped, reviewed work, push the Task branch and create/update its one PR. Read existing remote state before retrying a mutation to avoid duplicate PRs/comments. For an accepted local contract without a GitHub issue, include the contract, concise acceptance-to-evidence summary, commands/results, both review axes, remaining nonblocking findings, and verified implementation commit in the PR as before.

For an assigned GitHub issue, reread its current title before creating/updating the PR and again before handoff. Apply the shared policy's title format, set the PR body to the empty string without template autofill, and verify both from the saved PR. Resolve the exact issue and PR node IDs, then link them with GitHub GraphQL `addCloseIssueReferences`; read `closingIssuesReferences` before linking or retrying, and verify it contains only the assigned issue before handoff. Resolve or report any extra closing references; do not link parent or dependency issues merely mentioned for context.

Keep one handoff comment on the assigned issue for this PR. Find any existing comment by this agent that identifies the same PR URL, update it on resume, or create it if none exists; never edit another author's comment. If another author already left a handoff comment for this PR, report the ownership conflict instead of creating a duplicate. Include the PR URL, verified implementation commit, concise acceptance evidence, commands/results, both review axes, and remaining nonblocking findings. Reread the comment after writing it. If native linking or comment updates lack permission, or repository-required CI or instructions conflict with an empty PR body, report the unmet requirement and do not claim readiness. For GitHub Projects work, also verify the default-branch target and follow the repository's delivery and lifecycle rules. Do not claim a human-owned acceptance or deployment transition.

Wait for required CI for the current PR revision. Fix in-scope failures on the same branch/PR, rerun affected checks and review, and update evidence after pushing. Do not use a green run from an earlier revision. For GitHub issue work, update the handoff comment with the current revision's CI result before handoff. External failures or missing access must be reported without claiming readiness or relaxing required checks.

Hand off only after required checks and both review axes are satisfied for the delivered code. For GitHub issue work, also verify the current issue title, empty PR body, native closing link, and issue comment's evidence for the delivered revision. Apply the repository's handoff lifecycle transition then. When an orchestrator owns lifecycle mutations or CI evidence, use its provided interface and report outcomes rather than competing with it; do not create a second execution record in the checkout.

Return the PR, scope delivered, verification/review result and concrete remaining human acceptance. A narrow standalone invocation stops at the user's requested boundary rather than implicitly publishing.
