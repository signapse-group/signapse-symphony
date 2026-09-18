---
name: to-spec
description: Synthesize agreed context into a structured brief in chat, without an interview or publication.
---

# To Spec

Produce a tool-independent brief from the conversation and established evidence. Preserve the user's latest accepted decisions, meaningful identifiers, references and rationale. Inspect code or domain docs only for relevant facts not already established.

Keep requirements traceable to accepted needs or verified constraints. Distinguish assumptions and proposals from decisions; omit superseded options unless their rationale matters. Do not add requirements to fill a template or silently resolve conflicts.

Require repository adoption and load [workflow](../workflow/SKILL.md). Apply the shared [business analysis guidance](../workflow/references/business-analysis.md) when checking requirement quality and alignment with the accepted need. Preserve established need evidence, outcome assumptions and evaluation methods in the brief; surface material gaps under Open Questions.

## Content and Precision

Include the desired outcome, sufficient scope and observable acceptance, accepted technical/testing decisions, exclusions and known work boundaries where established. Use user stories only when an actor helps. Avoid repeating the same requirement under several headings.

For a bug, preserve expected behavior and basis, actual behavior, impact, reproduction/observation, evidence, fix scope and verification requirements.

Source paths or short snippets are useful when they make a decision precise; identify them as current evidence or an accepted contract shape, not a permanent implementation prescription. Preserve prototype decisions without copying a demo.

Separate consequential unresolved decisions under Open Questions from routine implementation details left to the implementing agent. A seam that can be chosen under repository standards is not a missing human decision or a readiness blocker. Record established verification requirements without inventing a test approach.

For a broad brief that benefits from a scaffold, consult [brief-template.md](brief-template.md). It is optional; use only sections that carry distinct information.

## Completion

Return the brief in chat and make any material gaps visible. Do not interview, ask for reconfirmation, create files/issues or invoke publication as part of synthesis. An explicit subsequent request supplies its own authority.
