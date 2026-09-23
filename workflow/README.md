# Agent Workflow Skills

This repository contains reusable Codex skills for human-led technical design and for implementing an assigned contract through verification, independent review, and delivery handoff. Product discovery, requirement definition, issue decomposition, and issue publication belong to the planning repository or another upstream process.

## Included skills

- `agent-execution-policy`: shared execution and delivery policy for adopting repositories.
- `setup-workflow`: inspect a repository and configure its project-specific workflow adoption and Symphony entrypoint.
- `implement`: deliver assigned work through checks, independent review, PR, and required CI.
- `tdd`: verify changed behavior at stable public seams.
- `code-review`: review requirement adherence and technical correctness.
- `diagnosing-bugs`: build a tight reproduction loop and identify root cause.
- `resolving-merge-conflicts`: resolve an active merge or rebase while preserving intent.
- `codebase-design`: design deep modules, interfaces, and test seams.
- `technical-design`: inspect related issues and implementation repositories with a human technical owner, then propose a design before autonomous execution.

## Install

The source repository is `signapse-group/signapse-symphony`. The reusable skills are stored under `workflow/skills`; the Elixir Symphony runtime and the repository's internal `.codex/skills` are separate and are not part of this collection.

From the root of the consuming repository, install the complete collection into the project scope:

```powershell
npx skills@latest add https://github.com/signapse-group/signapse-symphony/tree/main/workflow/skills `
  --agent codex `
  --skill "*" `
  --copy `
  --yes
```

The URL points directly to `workflow/skills`, so the wildcard selects its nine valid `SKILL.md` files, including `technical-design`. `--copy` makes the project installation independent of symlink support. Do not run this command from the Symphony source repository when setting up another project; run it from the target repository so the skills are installed into that project's scope.

For a personal installation shared across repositories, add `--global`. For a smaller project installation, replace `--skill "*"` with the required skill names, such as `--skill agent-execution-policy --skill technical-design --skill codebase-design` for design work.

After installation, start a new Codex conversation so it reloads the skill catalog. From the target repository, invoke `$setup-workflow`; it will inspect the repository and draft the `AGENTS.md` adoption block and, when Symphony is used, the root `WORKFLOW.md`.

To preview the repository's discovered skills before installing them:

```powershell
npx skills@latest add https://github.com/signapse-group/signapse-symphony/tree/main/workflow/skills --list
```

Update a project-scoped installation with `npx skills update -p`. Review the resulting files when the installation is committed to the consuming repository. Symphony workers must receive the same project-scoped installation after cloning, or use a verified equivalent provisioning step on every worker host.

## Adopt the execution workflow

Installing the skills does not activate repository lifecycle behavior. Run `$setup-workflow` to draft the project-specific adoption block in root `AGENTS.md` and, when Symphony is used, create or update its root `WORKFLOW.md`.

The skill is explicit-only because it can update repository instruction and orchestration files. It shows the complete drafts and waits for acceptance before writing. The generated Symphony prompt loads `$agent-execution-policy` and invokes `$implement`; shared execution policy stays in the installed skills rather than being copied into each repository.

```markdown
## Agent Workflow

This repository adopts the Agent Workflow execution skills.
At the start of each new session, read `$agent-execution-policy` before workflow-dependent action.

- Repository role and contract source: ...
- Focused and completion checks: ...
- Required CI: ...
- Delivery condition and issue-linking rule: ...
- Human acceptance owner: ...
- Relevant architecture and contract locations: ...
- Output language: ...
```

For Symphony workspaces, ensure the project-scoped skills are committed with the repository or otherwise provisioned and verified on every worker host. Keep tracker credentials outside `WORKFLOW.md`.

Planning repositories remain responsible for producing and publishing Task/Bug contracts. An explicitly accepted local contract is also valid input when the user assigns it directly.

After planning has divided a feature into implementation issues, a human technical owner may invoke `$technical-design` to inspect the relevant repositories and agree on a codebase-grounded design. The skill does not run inside Symphony's unattended implementation loop or move issues to `Ready`; the owning repository defines readiness and the human accepts material design decisions.

## Validate

Validate every changed skill, then validate the collection:

```powershell
python <skill-creator>/scripts/quick_validate.py workflow/skills/<skill-name>
python workflow/tests/validate_package.py
```

The collection validator checks the expected skill set, local links, encoding, line endings, and forbidden project-specific coupling.
