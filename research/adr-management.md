# Managing architecture decisions alongside requirements

## Findings from primary sources

- AWS defines an ADR as a record of a significant architectural choice, including its context and consequences. AWS recommends a lifecycle such as Proposed, Accepted, and Rejected; accepted ADRs are immutable, and a later decision supersedes the earlier one rather than editing its history. Source: [AWS Prescriptive Guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/architectural-decision-records/adr-process.html).
- Microsoft Azure recommends ADRs only for architecturally significant requirements: choices that affect system structure, key quality attributes, or are difficult to reverse. Its suggested record includes context, options, decision, trade-offs, confidence, consequences, and status. Source: [Microsoft Azure Well-Architected Framework](https://learn.microsoft.com/en-us/azure/well-architected/architect-role/architecture-decision-record).
- The ADR organization defines an ADR as one justified design choice addressing an architecturally significant functional or non-functional requirement. A collection of ADRs forms a decision log, and each record should preserve rationale, trade-offs, and consequences. Source: [adr.github.io](https://adr.github.io/).
- MADR provides a lightweight Markdown format for one decision at a time. Its examples separate context, considered options, and decision outcome, which keeps a decision record smaller than a design document. Source: [MADR](https://adr.github.io/madr/).

## Common operating model in larger projects

1. A requirement or issue identifies the user/business outcome and the acceptance boundary.
2. A design discussion, RFC, or issue comment explores alternatives and gathers review.
3. When a decision passes an architecture-significance threshold, one ADR records the accepted choice and its rationale.
4. The implementation issue links to the ADR and maps the affected acceptance criteria to implementation work.
5. The ADR is reviewed and accepted by an identified owner or architecture group.
6. Accepted ADRs are treated as append-only. A changed decision creates a new ADR that supersedes the old one.
7. A small index or generated catalog makes the decision log searchable by status, area, and superseded-by links.

## Boundary between issues and ADRs

Keep in an issue:

- user or operator outcome;
- acceptance criteria and meaningful failure/authorization cases;
- scope and exclusions;
- business rules and externally observable quality constraints;
- dependencies, ownership, and delivery status.

Keep in an ADR:

- a choice among credible architectural alternatives;
- why the choice affects structure, integration boundaries, quality attributes, or long-term lock-in;
- consequences and migration implications;
- status, owner, review date or supersession links.

Do not create an ADR merely because an implementation detail appears in an issue. A database table, endpoint, framework, query pipeline, or backend/frontend split belongs in a Task unless it is itself an accepted architectural choice with meaningful trade-offs.

## Recommendation for an issue-first adopting repository

Use an issue-first model with a narrow ADR gate:

- GitHub Issues remain the source of truth for Epics, Stories, Tasks, acceptance, scope, and status.
- A design discussion stays in the issue, issue comments, or a short RFC while the decision is unsettled.
- Create an ADR only when all three conditions hold: the choice is hard to reverse, surprising without its rationale, and the result of a real trade-off.
- Store ADRs in `docs/adr/` as numbered Markdown files with `Proposed`, `Accepted`, `Rejected`, or `Superseded` status. Keep an `index.md` or generated list with owner, status, affected area, and supersession links.
- An ADR should be linked from the owning issue, but it should not replace the issue or duplicate its acceptance criteria.
- Once accepted, the issue should retain only the user-visible or contract-relevant consequences. Implementation Tasks may reference the ADR for the chosen architecture.
- Requirement-only workflow runs must not create or update ADRs automatically. ADR creation should require an explicit architecture-documentation request or a repository policy that names ADR publication as a deliverable.

For example, “administrators can enable or disable system email and invalid SMTP candidates do not replace the active configuration” belongs in a Story. “Use one database-backed SMTP configuration instead of deployment properties or a provider catalog” is an ADR candidate only after the team has explicitly accepted that architectural trade-off.
