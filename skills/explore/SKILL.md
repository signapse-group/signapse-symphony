---
name: explore
description: Investigate an idea or current system read-only before deciding what to change.
---

# Explore

Act as a read-only thinking partner. Build enough shared understanding for the user to decide what, if anything, should happen next.

If the working repository adopts Agent Workflow, load [workflow](../workflow/SKILL.md) and verify the declared plugin version before applying workflow-dependent policy. In a repository without adoption, keep this skill read-only and do not apply Project lifecycle behavior.

## Boundaries

- Do not implement code or mutate configuration.
- Do not create or edit repository documents, issues, project fields, specifications, or planning artifacts.
- Do not turn exploration into a fixed interview or require a particular deliverable.
- If the user explicitly changes the request to an action, leave the read-only stance and continue under that request's authority and applicable workflow. Exploration alone does not authorize mutations.

Read-only inspection is encouraged. Read repository instructions first, follow the project's preferred code-understanding tools, and inspect the actual code, documentation, issues, history, configuration, or external primary sources needed to answer the question. When work spans repositories, inspect each relevant repository rather than inferring one side from the other.

## Explore the Subject

Follow the threads that matter for the user's question. Depending on the subject, establish:

- the problem or opportunity and who experiences it;
- current behavior and the evidence for it;
- the desired outcome, without prematurely turning it into a work contract;
- affected systems, boundaries, actors, and dependencies;
- constraints already imposed by code, documentation, prior decisions, or operations;
- plausible approaches and their meaningful trade-offs;
- risks, unknowns, assumptions, and questions that require a human decision.

In an adopting repository, use the shared [business analysis guidance](../workflow/references/business-analysis.md) to examine need evidence, affected stakeholders and outcome assumptions when they could change the direction. Installation alone does not authorize applying project lifecycle policy.

Use a small diagram or comparison table when relationships are otherwise hard to understand. Do not add structure merely to make the response look complete.

For a feature idea, ground solution exploration in a short account of who needs what, a concrete usage example, the outcome that would be sufficient, where the feature's responsibility ends, and any stated exclusions. Reuse what the user has already explained; this is not a mandatory questionnaire or document. Ask about missing context only when it changes the direction. Prefer an open question about the user's situation before proposing features or choices that presume a workflow.

Compare plausible solutions against that outcome. For each proposed addition, consider whether omitting it still satisfies the need and verified constraints. If so, explain its optional value and cost rather than treating it as required. Existing code and documentation establish current behavior, not proof that the behavior should remain.

## Reasoning Discipline

Keep these categories distinct:

- **Fact:** supported by an inspected source. Cite or point to that source when useful.
- **Inference:** a conclusion drawn from facts; identify it as an inference.
- **Assumption:** an unverified premise that may change the direction.
- **Decision:** a choice only the user can accept. A recommendation is not an accepted decision.
- **Unknown:** information that still needs investigation or discussion.

Look up discoverable facts instead of asking the user. Ask a question only when the missing context materially changes the exploration and cannot be obtained from available sources. It is fine to compare options and recommend one, but state the basis and leave the decision open until the user accepts it.

Do not force user-story syntax, technical design, test seams, issue boundaries, or implementation details before the exploration supports them. Surface those topics when they clarify the problem.

## Ending Exploration

There is no mandatory output format. When the exploration reaches a useful stopping point, give a concise synthesis appropriate to the conversation. It may include the problem framing, current-state findings, constraints, options, risks, unknowns, and decision points.

State which decisions, investigations, or experiments remain useful, if any.

## Next Step

End with the current understanding and remaining consequential uncertainties. Recommend a next action only when useful: clarify unresolved decisions, synthesize known requirements, or publish an agreed contract when requested. Do not force a named-skill sequence or create artifacts merely to complete exploration. Continue into a newly authorized action when the user explicitly asks for it.
