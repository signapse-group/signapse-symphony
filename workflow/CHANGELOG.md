# Changelog

## 0.4.0 - Unreleased

- Standardize issue-backed PR titles, empty bodies, native issue closing links, and issue comment handoff evidence across the shared workflow.
- Add the explicit-only `technical-design` skill for human-led design from already divided implementation issues and verified repository code.
- Add the explicit-only `setup-workflow` skill to configure the Symphony entrypoint in `WORKFLOW.md` without changing repository instructions.
- Activate the shared execution policy through an assigned Symphony prompt or explicit human request rather than an `AGENTS.md` adoption block.
- Make Symphony execution intrinsic to `setup-workflow` and separate repository-owned workflow facts from deployment-owned runtime settings so onboarding reuses the deployed profile instead of asking users to configure the host again.
- Add the GitHub Projects v2 setup profile: `Ready` dispatches work, `In progress` remains active, `In review` hands off to humans, and `Done` terminates work.
- Rename the shared `workflow` skill to `agent-execution-policy` to distinguish it from Symphony's `WORKFLOW.md` runtime file.
- Convert the package from a Codex plugin to an execution skill collection.
- Move discovery, requirement definition, issue publication, domain documentation, research, prototyping, and bug intake out of this repository's distributed skills.
- Narrow the shared workflow to assigned implementation, verification, independent review, PR/CI handoff, implementation decisions, and API delivery evidence.

## 0.3.3 - Unreleased

- Strengthen Story boundary checks so planning separates independently valuable stakeholder outcomes without splitting mechanically by CRUD action or technical surface.
- Require acceptance-significant terms and shared quality rules to have clear ownership and verifiable definitions before publication.

## 0.3.1 - Unreleased

- Add Story implementation-leakage guidance so backend/frontend references remain only when they express verifiable security, privacy, data-integrity, localization, reliability, or compatibility constraints.
- Clarify that surface-specific Tasks require independent deliverables and verification boundaries.

## 0.3.0 - Unreleased

- Decouple repository adoption from the installed plugin version so routine upgrades do not require `AGENTS.md` edits.
- Treat missing plugin availability or required repository configuration as the workflow bootstrap blocker.

## 0.2.1 - Unreleased

- Simplify Story contracts by removing generic context and relationship-reference sections.
- Keep Open Decisions only while material decisions remain unresolved, then incorporate accepted results into the owning contract sections.

## 0.2.0 - Unreleased

- Improve Epic and Story contract templates with outcome traceability, business rules, and quality constraints.
- Add contract-quality checks to `to-ticket` for vertical Story boundaries, requirement coverage, dependencies, and readiness.

## 0.1.0 - Unreleased

- Add a GitHub marketplace with two-command installation.

- Extract the shared planning, execution, verification, review, issue, and delivery workflow.
- Package 16 workflow and supporting skills with their resources and invocation metadata.
- Add explicit repository adoption, policy bootstrap, version-mismatch, and non-adopted repository boundaries.
