# Cross-repository API handoff

The adopting repository's `AGENTS.md` defines producer/consumer repositories, planning ownership, Project identity, delivery conditions, and `Refs`/`Closes` rules. Use full URLs across repositories and native relationships.

For a producer API Task and consumer integration Task, maintain one `API Contract` comment on the producer Task. Include agreed observable behavior, request/response shapes, authorization, business rules, error behavior, and examples. Link the exact comment URL from the consumer Task.

The planning contract is not delivery evidence. The producer refines it against implementation before review. Delivery evidence identifies the accepted revision/version and the repository-specific deployment or handoff condition. Mocked consumer behavior does not establish producer delivery.

If the contract is insufficient for consumer integration, keep that work Open or otherwise not ready under the configured lifecycle. Do not invent endpoints, fields, errors, or deployed versions. A later incompatible change uses a new Task/comment linked to the prior handoff rather than rewriting frozen completion evidence.
