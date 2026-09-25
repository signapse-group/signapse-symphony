# Shared execution workflow

This policy applies when a Symphony prompt assigns work and loads it, or when the user explicitly requests it for the current scope. Installation and repository instructions alone do not activate issue lifecycle behavior.

## Authority and flow

Assigned Task/Bug or accepted local contract → implementation and verification → independent review → findings resolved → PR and required CI ready → human review and the repository delivery condition.

Implementation requires an explicit assignment or accepted local contract. Read the current contract and its relevant references and dependencies; do not create, decompose, publish, or silently broaden product requirements. The user's request and repository policy determine authorization for status changes, branches, pushes, and PR creation or updates. Human owners retain the contract, material decisions, merge, deployment, and acceptance unless explicitly delegated.

## Execution and completion

Use one branch/worktree and one PR per assigned deliverable. Resume the same deliverable on the same branch and PR.

1. Read the current contract, relevant references and dependencies, this policy, and repository instructions if present.
2. Inspect the checkout and ownership of dirty files. State the implementation scope, verification seam, and material risks.
3. Implement the smallest accepted change. Run focused checks while iterating and the repository's completion checks before handoff.
4. Have one independent reviewer inspect the complete relevant working state and report Requirement adherence separately from Correctness & Standards.
5. Resolve blocking findings, reverify affected behavior, and re-review affected parts.
6. Create or update the PR. Record contract coverage, commands/results, both review axes, nonblocking findings, and the verified revision in the issue handoff comment for GitHub issue work, or in the PR for an accepted local contract. Resolve required CI for that revision.

Work is ready for human review when required checks, independent review, and required CI pass for the delivered revision. Missing required evidence, access, or review is not a pass. Manual owner acceptance is not unfinished agent work unless explicitly assigned.

For a PR implementing an assigned GitHub issue, set the title to `[#<issue-number>] <current issue title>` for an issue in the PR's repository, or `[<owner>/<repo>#<issue-number>] <current issue title>` for an issue in another repository. Leave the PR body completely empty. Link only the exact assigned issue as a native closing reference, and verify it through `closingIssuesReferences` before handoff; a title, URL, or `Refs` alone does not create this link. Record the PR URL, verified implementation commit, acceptance evidence, commands/results including required CI, both independent-review axes, and remaining nonblocking findings in one agent-owned handoff comment on that issue. The comment must describe the delivered revision. If repository-required CI or instructions conflict with an empty PR body, report the conflict rather than weakening those requirements or claiming readiness.

For assigned GitHub Projects implementation issues, target the repository's default branch. The agent stops at the review handoff: a maintainer reviews and merges, GitHub closes the linked issue, and the Project's enabled `Item closed` workflow moves it to `Done`. The agent must not merge, close the issue, or move it to `Done`. Confirm that this Project workflow is enabled; do not assume it from the status names alone.

## Execution status

| Status | Meaning | Owner |
| --- | --- | --- |
| In progress | Assigned execution, verification, review fixes, or CI work is active. | Agent |
| Blocked | Execution started, material input/access is required, and no meaningful independent work remains. | Agent |
| In review | Current PR revision has required checks, independent review, and required CI. | Agent |
| Done | Contract and repository delivery condition are satisfied. | Repository delivery policy |

Feedback requiring changes returns work to In progress. A hard task or failing implementation test is not itself Blocked. Cancellation and replacement follow human decisions and remain distinct from Done.

Determine the repository's delivery condition and any tracker-specific exceptions from the assigned prompt and repository sources. Merge may complete an implementation issue in one repository while another requires deployment or handoff confirmation. Do not infer one repository's condition from another.

### Blocker comments and resume

For assigned GitHub issue work, investigate the blocker and identify the human action needed before stopping. Once the Blocked conditions above hold, read the issue's current status and comments. Create a blocker comment on that issue, or update this agent's existing comment for the same blocker; never edit another author's comment. Read back the saved comment before changing In progress to Blocked, then verify the status before ending the run. Retry from current remote state to avoid duplicate comments or repeated transitions.

Use this concise template in the repository's output language, replacing the resume state with the repository workflow's dispatch state:

```markdown
**Blocked**
- Reason: <What prevents progress.>
- Checked: <What was tried and the result; evidence link if useful.>
- Needed: <Specific action or decision required from a human.>
- Resume: <Condition to proceed>; reply here, then move to <dispatch state>.
```

Keep each item to about one sentence and link evidence instead of pasting long logs. Include a short recommendation in Needed when a decision requires choosing an option. The issue comment is the notification; no mention or separate notification channel is required.

If writing or verifying the comment fails, report the failure in the working session and do not change the status to Blocked. If changing or verifying the status fails, preserve the comment and report the unconfirmed transition; do not claim it succeeded.

After resolving the blocker, the human records the resolution on the issue and moves it to the repository's dispatch state. On resume, reread the issue and comments, verify the required input is available and the blocker is resolved, then continue the same branch/PR. A status change alone does not resolve a blocker.

## Contract changes during execution

Investigate discoverable facts before treating uncertainty as a contract gap. Routine implementation choices remain with the implementer under repository standards. For an unresolved material decision, use [decision-gate.md](decision-gate.md).

An accepted change within the same deliverable updates the execution plan and invalidates affected checks or review. A different deliverable or boundary requires a human replacement or cancellation decision. Do not absorb new requirements into active or completed work.

## Evidence and activation

The consuming repository decides the language for agent responses, issue handoff comments, PR bodies where applicable, and generated artifacts. Read that setting from the assigned prompt or repository instructions; these English skill files are not an output-language requirement.

Evidence lives in the working session, PR, and configured tracker; no parallel snapshot or fingerprint is required. Re-read live contracts when resuming and before handoff. Code, contract, dependency, or base changes invalidate only affected evidence.

For each assigned workflow run, load `$agent-execution-policy` and read project-specific facts before workflow-dependent action. If the skill is unavailable or required project-specific configuration is missing, report the blocked portion and continue valid independent work. Individual skills may serve ordinary user requests without applying this lifecycle. Do not edit `AGENTS.md` to activate it.
