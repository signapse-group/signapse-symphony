# Agent Workflow

`agent-workflow` packages a shared planning-to-delivery workflow for Codex desktop and CLI. It includes workflow policy, issue formats, decision and API handoff guidance, and reusable skills for exploration, specification, implementation, testing, review, diagnosis, and domain work.

## Install from GitHub

With Codex CLI installed and Git authenticated for this private repository, run:

```powershell
codex plugin marketplace add signapse-group/signapse-workflow
codex plugin add agent-workflow@signapse-workflow
```

Start a new conversation in the consuming repository, then follow the adoption section below. The marketplace manifest at `.agents/plugins/marketplace.json` points to the plugin at this repository's root; no Python, scaffolding, or manual file copy is needed for this installation.

## Local development installation

For a personal installation, first let `plugin-creator` create the supported marketplace entry and destination:

```powershell
python <plugin-creator>/scripts/create_basic_plugin.py agent-workflow --with-skills --with-marketplace
```

Copy the complete released package over the generated `~/plugins/agent-workflow` directory, including `.codex-plugin/plugin.json`, `skills/`, and top-level documentation. Validate that directory, then install it using the marketplace name returned by `read_marketplace_name.py`:

```powershell
python <plugin-creator>/scripts/read_marketplace_name.py
codex plugin add agent-workflow@<marketplace-name>
```

The default personal marketplace is discovered automatically; do not add it with `codex plugin marketplace add`. For a team marketplace, scaffold with explicit `--path` and `--marketplace-path`, copy the release into the generated `plugins/agent-workflow` directory, add that non-default marketplace root when needed, and install from its validated marketplace name. Start a new conversation after installation or update so Codex loads the packaged skills.

## Adoption

Installing the plugin does not adopt it for every repository. A consuming repository must add a section like this to its root `AGENTS.md`:

```markdown
## Agent Workflow

This repository adopts the `agent-workflow` plugin version `0.2.0`.
At the start of each new session, read `$workflow` and verify the installed version before workflow-dependent action. If the plugin is missing or mismatched, report the blocked portion and continue only independent valid work.

- Repository role and planning/execution repositories: ...
- GitHub Project owner/number: ...
- Focused and completion checks: ...
- Required CI: ...
- Delivery condition and Refs/Closes rule: ...
- Human acceptance owner: ...
- Domain context and ADR locations: ...
```

Keep coding standards, technology-specific test seams, application commands, repository identity, and delivery facts in that repository's `AGENTS.md`. Remove active local copies of skills replaced by this plugin so duplicate names do not coexist.

## Local validation

From the plugin source directory, run:

```powershell
python tests/validate_package.py
python <plugin-creator>/scripts/validate_plugin.py .
```

Validate every changed skill with `skill-creator/scripts/quick_validate.py <skill-directory>`. Test installation and upgrades in a new conversation. Before adoption, verify whether the installed plugin version is shared across repositories; coordinate upgrades when the runtime cannot isolate versions per repository.

Static package validation is the P1 gate. Runtime acceptance for policy bootstrap, non-adopted repositories, GitHub fixtures, multi-repository version mismatch, upgrade, and rollback requires an installed marketplace build in fresh conversations; do not claim P2 complete from the static validators alone.

## Upgrade and rollback

Test a candidate release in a new conversation before updating repository adoption declarations. If one installation serves multiple repositories, verify each affected repository against the candidate. Roll back the installed release and the affected adoption declarations together, then start new conversations to confirm the active policy. Do not keep duplicate active copies of the same skills as a rollback mechanism.

## Removal

Remove the plugin through the Codex plugin manager, restore or select another workflow in the repository's `AGENTS.md`, and start a new conversation. Removing this plugin does not roll back application code or GitHub state.
