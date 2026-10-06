# Symphony

## Repository Workflow

`elixir/WORKFLOW.md` owns this repository's unattended execution prompt and GitHub Project lifecycle.
Each consuming repository owns its own `WORKFLOW.md`, implementation instructions, and optional skills.

- Repository role and contract source: maintain the Symphony Elixir runtime; assigned GitHub Project issues are the implementation contract.
- Focused and completion checks: targeted `mix test` checks in `elixir`; completion gate `make -C elixir all`.
- Required CI: `make-all` and `pr-description-lint` workflows.
- Delivery condition: maintainer merge into the default branch completes the implementation issue; the Project's `Item closed` workflow sets Status to `Done`. Release and deployment remain human-owned and do not delay issue completion.
- Human acceptance owner: Signapse maintainers.
- Relevant architecture and contract locations: `SPEC.md`, `elixir/README.md`, `elixir/WORKFLOW.md`, `elixir/lib/symphony_elixir/`, and `.github/workflows/`.
- Output language: English unless the assigned work item requests another language.
