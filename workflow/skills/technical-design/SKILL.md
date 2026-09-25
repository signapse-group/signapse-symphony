---
name: technical-design
description: Collaborate with a human technical owner to design an implementation from an already divided set of product, backend, and frontend issues, grounded in the affected repositories. Use before autonomous implementation; do not use to define product requirements or implement the issues.
---

# Technical Design

Run this skill with the human technical owner after upstream planning has produced the related implementation issues. The outcome is a codebase-grounded design and an issue handoff the human can accept. This is a human-led activity outside Symphony's unattended implementation loop. Read repository instructions if present; load [agent-execution-policy](../agent-execution-policy/SKILL.md) only when the human explicitly requests that workflow for this scope. This skill does not invoke [implement](../implement/SKILL.md).

## Build the design context

Read the current Epic/Story and all affected backend/frontend Tasks, decision comments, dependencies, and linked contracts. Use exact repository-qualified issue references. Separate accepted requirements from planning suggestions, unresolved decisions, and assumptions. Map each acceptance criterion to its intended implementing issue; flag omissions, overlap, or a task split that does not fit the code. Planning owns product requirements and issue publication, so propose changes to the human rather than silently changing them.

Inspect the relevant working trees, repository instructions, architecture documentation, existing flows, data models, API shapes, and tests. For a cross-repository feature, inspect each affected repository before making claims about its code. Cite paths and concrete behavior for findings; label any inaccessible repository or unverified assumption. Identify shared policy or data decisions across the issue set before designing individual tasks.

## Develop the proposal together

Recommend a coherent design that fits the observed code: responsibilities, data and migration, consistency and concurrency, failure and retry behavior, security/authorization, cross-repository contracts, and verification seams where relevant. Apply [codebase-design](../codebase-design/SKILL.md) when deciding module interfaces or seams; do not force a new module or abstraction merely to use that vocabulary. Compare realistic alternatives only for material trade-offs, and state the recommended option and why.

Bring unresolved material decisions to the human with the evidence, options, recommendation, and which work depends on the answer. Continue investigation and independent design work while waiting. Record the human's decisions distinctly from agent recommendations; silence is not acceptance. If a decision changes product behavior or task boundaries, identify the owning contract and proposed update for the human. Do not invent an endpoint, error shape, or dependency completion for a consumer task.

## Hand off a reviewable design

Present or draft the design in the location the human or repository specifies. A shared feature design may cover several tasks; link repository-specific sections or documents when that makes ownership clearer. Include only the detail needed for implementation and review:

- Source issues and acceptance coverage, with proposed corrections to task boundaries or dependencies.
- Verified current behavior and relevant code references, plus access limits and assumptions.
- Chosen technical approach and cross-repository contract, including important failure and data cases.
- Verification approach, rollout or migration implications where applicable, and open decisions.
- Human decision record and links to the accepted version of the design.

Treat a draft as a proposal until the human explicitly accepts the material decisions. Acceptance authorizes the design as input to the repository's implementation readiness process; it does not itself authorize issue edits, status transitions, implementation, or producer delivery claims. Report what remains before each task can be marked ready under the owning repository's policy. Revisit affected design decisions if code or contracts change before implementation.
