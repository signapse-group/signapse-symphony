# Symphony

## Agent Workflow

This repository adopts the Agent Workflow execution skills.
At the start of each new session, read `$agent-execution-policy` before workflow-dependent action.
`elixir/WORKFLOW.md` is the Symphony runtime entrypoint for assigned GitHub Project work; repository instructions remain here.

- Repository role and contract source: maintain the Symphony Elixir runtime and reusable Agent Workflow skills; assigned GitHub Project issues are the implementation contract.
- Focused and completion checks: targeted `mix test` checks in `elixir`; completion gate `make -C elixir all` and `py -3 workflow/tests/validate_package.py`.
- Required CI: `make-all` and `pr-description-lint` workflows.
- Delivery condition and issue-linking rule: target the default branch and include `Closes <owner>/<repo>#<issue-number>` in the PR body for the exact assigned implementation issue. Before handoff, verify that issue appears in the PR's Development section or `closingIssuesReferences`; `Refs` or a plain URL is insufficient. Do not use closing keywords for parent or dependency issues included only as references.
- Handoff and completion: move the issue to `In review` only after required checks, independent review, required CI, and issue-link verification pass for the delivered revision. A human-reviewed merge into the default branch completes the implementation issue: GitHub closes it and the Project's enabled `Item closed` workflow sets Status to `Done`. Agents stop at `In review` and must not merge, close the issue, or move it to `Done`. Release and deployment remain human-owned and do not delay implementation issue completion.
- Human acceptance owner: Signapse maintainers.
- Relevant architecture and contract locations: `SPEC.md`, `elixir/README.md`, `elixir/lib/symphony_elixir/`, `workflow/skills/`, and `.github/workflows/`.
- Output language: English unless the assigned work item requests another language.
