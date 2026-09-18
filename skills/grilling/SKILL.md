---
name: grilling
description: Clarify needs and stress-test consequential decisions without expanding scope by default. Use when the user wants to grill a plan, decision, or idea.
---

# Grilling

If the working repository adopts Agent Workflow, load [workflow](../workflow/SKILL.md) before applying workflow-dependent policy. In a repository without adoption, use this skill only for the requested clarification and do not apply Project lifecycle behavior.

Resolve uncertainties that materially affect the need, scope, or solution choice. Start with the desired outcome, a concrete usage example, and what would be sufficient, using the conversation before asking for missing information. For an already bounded plan or technical decision, work within its established purpose instead of restarting product discovery.

Default to one consequential decision at a time and wait before dependent decisions. Group a few independent factual inputs when that is easier for the user; do not bundle dependent choices or infer acceptance from silence. Elicit the user's situation and expectations with open questions before offering solutions. When a decision needs options, explain meaningful trade-offs and recommend an answer based on the established need. Include omission or a simpler approach when viable; do not frame every option as adding the same unproven capability.

Look up discoverable facts rather than asking the user. Distinguish user decisions, verified constraints, and agent proposals. Existing behavior alone does not establish a requirement to preserve it. Leave routine implementation choices to the agent under repository standards and accepted scope.

Before adding a capability, assess whether removing it would still meet the accepted need and verified constraints, including correctness and security. If it would, present the addition as optional with its value and cost. A materially new actor, workflow, integration, or team obligation warrants a short comparison of the old and proposed scope and the resulting whole user journey before the user decides on that expansion.

In an adopting repository, apply the shared [business analysis guidance](../workflow/references/business-analysis.md) to concrete examples, stakeholder trade-offs, outcome evaluation and transition needs where they affect this decision.

An agreement accepts the current question only. Preserve accepted decisions; do not reopen them without new conflicting evidence or an explicit user request. Do not require repeated approval of unchanged scope.

Stop when the outcome, main journey, boundaries, and consequential constraints are clear enough to describe a suitable solution. Do not exhaust hypothetical branches. Summarize the whole understanding and any deferred or unresolved matters so the user can confirm it; a prior explicit confirmation is sufficient. This interview does not itself authorize implementation or publication. Follow an explicitly invoked documentation wrapper for recording accepted decisions.
