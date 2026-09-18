---
name: grill-with-docs
description: Clarify decisions with the user and record accepted domain terms or durable architecture decisions.
---

# Grill with Docs

Require repository adoption and load [workflow](../workflow/SKILL.md), verifying the declared plugin version before workflow-dependent documentation. Use [grilling](../grilling/SKILL.md) for the conversation. This wrapper owns selective documentation, not a second interview process. Read existing domain context/ADRs only where they bear on the topic; follow repository locations and formats.

## What to Record

| Accepted content | Action |
| --- | --- |
| Canonical domain term, distinction or invariant | Update the existing glossary/context using [domain-modeling](../domain-modeling/SKILL.md). |
| Architecture choice that is hard to reverse, surprising without context and based on a real trade-off | Create/update the relevant ADR using domain-modeling. |
| Decision the user explicitly wants maintained in a named document | Update that source in place. |
| Task requirements, scope, AC, assumptions, open questions or task-specific implementation/testing choices | Keep in chat for synthesis; do not turn these into glossary or ADR entries. |

Record eligible accepted decisions promptly. Related decisions may be grouped into one coherent edit before handoff; do not write unsettled choices or defer accepted documentation beyond the session's handoff. Link to existing sources instead of duplicating them. Do not create documents merely because this skill was invoked.

## Completion and Authority

Summarize accepted decisions, unresolved/deferred matters and documents changed when understanding is sufficient or the user stops. Do not require reconfirmation of unchanged accepted scope.

The interview does not itself authorize issues, Project mutations, implementation or specification/plan artifacts. If the user explicitly requests a next action, follow that request under its authority rather than treating the interview boundary as a required stop.
