# Cross-repository API delivery

The adopting repository's `AGENTS.md` identifies producer/consumer repositories, the contract source, delivery conditions, and issue-linking rules.

Treat the linked producer contract as the source for agreed observable behavior, request/response shapes, authorization, business rules, error behavior, and examples. Do not create or extend that contract as part of ordinary implementation.

The producer checks the contract against implementation before review and records any authorized clarification in the owning contract. Delivery evidence identifies the verified revision or version and the repository-specific deployment or handoff condition. Mocked consumer behavior does not establish producer delivery.

If the contract is insufficient for consumer integration, stop dependent work and raise the specific gap through the [decision gate](decision-gate.md). Do not invent endpoints, fields, errors, or deployed versions. Do not rewrite frozen completion evidence for a later incompatible change.
