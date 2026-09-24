# Symphony

## Agent Workflow

This repository adopts the Agent Workflow execution skills.
At the start of each new session, read `$agent-execution-policy` before workflow-dependent action.
`elixir/WORKFLOW.md` is the Symphony runtime entrypoint for assigned GitHub Project work; repository instructions remain here.

- Repository role and contract source: maintain the Symphony Elixir runtime and reusable Agent Workflow skills; assigned GitHub Project issues are the implementation contract.
- Focused and completion checks: targeted `mix test` checks in `elixir`; completion gate `make -C elixir all` and `py -3 workflow/tests/validate_package.py`.
- Required CI: `make-all` and `pr-description-lint` workflows.
- Delivery condition: maintainer merge into the default branch completes the implementation issue; the Project's `Item closed` workflow sets Status to `Done`. Release and deployment remain human-owned and do not delay issue completion.
- Human acceptance owner: Signapse maintainers.
- Relevant architecture and contract locations: `SPEC.md`, `elixir/README.md`, `elixir/lib/symphony_elixir/`, `workflow/skills/`, and `.github/workflows/`.
- Output language: English unless the assigned work item requests another language.
