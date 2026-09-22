# Agent Workflow Skills

This repository contains reusable Codex skills for implementing an assigned contract through verification, independent review, and delivery handoff. Product discovery, requirement definition, issue decomposition, and issue publication belong to the planning repository or another upstream process.

## Included skills

- `workflow`: shared execution and delivery policy for adopting repositories.
- `setup-workflow`: inspect a repository and configure its project-specific workflow adoption context.
- `implement`: deliver assigned work through checks, independent review, PR, and required CI.
- `tdd`: verify changed behavior at stable public seams.
- `code-review`: review requirement adherence and technical correctness.
- `diagnosing-bugs`: build a tight reproduction loop and identify root cause.
- `resolving-merge-conflicts`: resolve an active merge or rebase while preserving intent.
- `codebase-design`: design deep modules, interfaces, and test seams.

## Install

From the target repository, install the complete collection for Codex with the Skills CLI:

```powershell
npx skills@latest add signapse-group/signapse-workflow `
  --agent codex `
  --skill "*" `
  --copy `
  --yes
```

The command installs all eight skills, including `setup-workflow`, into the project scope. `--copy` keeps the installed files independent of symlink support. For a personal global installation, add `--global`; for a smaller install, repeat `--skill <name>` for the skills you need.

After installation, start a new conversation so the agent reloads the skill catalog. Then run `$setup-workflow` from the target repository.

To inspect the collection before installing it:

```powershell
npx skills@latest add signapse-group/signapse-workflow --list
```

To update project-scoped skills later, use `npx skills update -p`; review the resulting diff when the installed files are committed to the repository.

## Adopt the execution workflow

Installing the skills does not activate repository lifecycle behavior. A consuming repository that wants the shared execution workflow should add project-specific configuration to its root `AGENTS.md`:

Run `$setup-workflow` to inspect the repository and draft this block interactively. It is explicit-only because it can update `AGENTS.md`; the skill shows the full draft and waits for acceptance before writing.

```markdown
## Agent Workflow

This repository adopts the Agent Workflow execution skills.
At the start of each new session, read `$workflow` before workflow-dependent action.

- Repository role and contract source: ...
- Focused and completion checks: ...
- Required CI: ...
- Delivery condition and issue-linking rule: ...
- Human acceptance owner: ...
- Relevant architecture and contract locations: ...
- Output language: ...
```

Planning repositories remain responsible for producing and publishing Task/Bug contracts. An explicitly accepted local contract is also valid input when the user assigns it directly.

## Validate

Validate every changed skill, then validate the collection:

```powershell
python <skill-creator>/scripts/quick_validate.py skills/<skill-name>
python tests/validate_package.py
```

The collection validator checks the expected skill set, local links, encoding, line endings, and forbidden project-specific coupling.
