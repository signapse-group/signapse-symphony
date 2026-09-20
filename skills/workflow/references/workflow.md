# Shared agent workflow

This policy applies only in repositories that explicitly adopt the `agent-workflow` plugin in their root `AGENTS.md`, or when the user explicitly applies it to the current scope. Installation alone does not activate repository lifecycle behavior.

## Authority and flow

Need → explore or grill when material uncertainty remains → readable spec and issue plan when definition helps → tickets when publication is requested → assigned Task/Bug → implementation and verification → independent review → findings resolved → PR and required CI ready → human review and acceptance.

Do not force every request through every step. A clear local contract may be implemented directly. Requests to explore, review, or plan do not authorize implementation or publication. Explicit publication authorizes the scoped issue writes; explicit assignment of a Task/Bug authorizes status management, a task branch, push, and PR creation/update. Human owners retain the contract, material decisions, merge, deployment, and acceptance unless explicitly delegated.

## Execution and agent completion

Use one branch/worktree and one PR per assigned Task/Bug. Resume the same deliverable on the same branch and PR.

1. Read the current contract, relevant parent/references/dependencies, shared policy, and repository `AGENTS.md`.
2. Inspect the checkout and ownership of dirty files. State the implementation scope, verification seam, and material risks.
3. Implement the smallest accepted change. Run focused checks while iterating and the repository's completion checks before handoff.
4. Have one independent reviewer inspect the complete relevant working state and report Requirement adherence separately from Correctness & Standards.
5. Resolve blocking findings and reverify affected behavior. Re-review affected parts after changes.
6. Create or update the PR. Record contract coverage, commands/results, both review axes, nonblocking findings, and the verified revision. Resolve required CI for that revision.

Agent work is ready for human review when required checks, independent review, and required CI pass for the delivered revision. Missing required evidence, access, or review is not a pass. Manual owner acceptance is not unfinished agent work unless explicitly assigned.

## Project Status

| Status | Meaning | Owner |
| --- | --- | --- |
| Open | Contract is new or materially incomplete. | Human; issue publication may create initial membership |
| Ready | Task/Bug is clear enough to execute; dependencies may remain. This is not authorization to start. | Ticket publication within scope |
| In progress | Assigned execution, verification, review fixes, or CI work is active. | Agent |
| Blocked | Execution started, material input/access is required, and no meaningful independent work remains. | Agent |
| In review | Current PR revision has required checks, independent review, and required CI. | Agent |
| Done | Contract and repository delivery condition are satisfied. | Repository delivery policy; Epic/Story remain human-owned |

Feedback requiring changes returns work to In progress. A hard task or failing implementation test is not itself Blocked. Cancellation, replacement, and duplicates follow human decisions and remain distinct from Done.

Each repository declares its delivery condition and `Refs`/`Closes` rule in `AGENTS.md`. Merge may be sufficient for one repository while another requires deployment or handoff confirmation. Do not infer one repository's condition from another. Parent Epic/Story completion remains a human outcome decision.

## Planning and contract changes

`to-spec` owns session synthesis, issue decomposition, and readable draft contracts. `to-ticket` consumes a defined plan, reconciles live GitHub state, and publishes/verifies authorized issues. Equivalent already-defined input may go directly to publication; incomplete input returns to definition instead of being silently decomposed during publication. Both skills remain explicit-only.

Use Epic → Story → Task/Bug only when that hierarchy reflects real outcomes and deliverables. Do not create artificial parents. A Task has one independently deliverable result and verification boundary; do not split by technical layer or file count.

Keep shared design in the appropriate parent/reference and child-specific application in the child. Issue bodies describe durable work contracts, not agent skills, branches, or PR mechanics. Use native types, parents, sub-issues, and dependencies. Do not invent labels or Project fields absent from repository configuration.

Do not duplicate native parent, sub-issue, or dependency relationships in issue bodies. Keep rationale and external references only when they are needed to understand, execute, or verify the contract. In Stories, place them beside the specific contract term they support instead of adding generic context or reference sections. Include an Open Decisions section only while material decisions remain unresolved; after acceptance, incorporate the durable result into the owning contract section and remove the resolved item or empty section.

For an accepted change within the same deliverable, update the current contract and affected evidence. A different deliverable/boundary needs a human replacement or cancellation decision. A new requirement for completed work needs a new issue. Use [decision-gate.md](decision-gate.md) for unresolved material decisions.

## Evidence and adoption

The consuming repository decides the language for agent responses, issue bodies, generated documents, and other workflow outputs. Read that setting from the repository's `AGENTS.md` and preserve the requested language; the plugin's English resource files are implementation references, not an output-language requirement.

Evidence lives in the working session, PR, and configured tracker; no parallel snapshot or fingerprint is required. Re-read live contracts when resuming and before handoff. Code, contract, dependency, or base changes invalidate only affected evidence.

At each new session, an adopting repository must load `$workflow` and read project-specific facts before workflow-dependent action. Adoption is independent of the installed plugin version. If the plugin is unavailable or required project-specific configuration is missing, report the blocked portion and continue valid independent work. Routine plugin upgrades do not require changes to the repository's adoption declaration. In a repository without adoption, individual skills may serve a user request, but they must not apply this lifecycle, mutate Project state, or edit `AGENTS.md` to opt in.
