# Implementation decision gate

Use this gate during assigned execution when a material decision is not settled by the contract, repository policy, verified constraints, or existing authorization.

Investigate discoverable facts first. Present the decision with the accepted need, affected behavior, realistic options, recommendation, trade-offs, and the exact dependent work. Ask only what materially changes direction. Continue meaningful independent work while waiting; use Blocked only when none remains.

Do not treat elapsed time, a recommendation, or silence as acceptance. In a requirement or issue-publication flow, record an accepted decision in the issue or other contract that owns the work. Do not create or update an ADR or other architecture document from that flow unless the user explicitly requests architecture documentation or the repository policy names it as a deliverable. If durable mutation is unavailable, preserve the decision in the session and report the missing update.

After resolution, reread the current contract. Update the same deliverable and affected evidence when the accepted decision stays within its boundary. A changed deliverable requires human replacement or cancellation. Re-run checks and review invalidated by the decision, then continue the same PR where appropriate.
