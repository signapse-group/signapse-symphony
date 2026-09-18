# Domain documentation

The adopting repository declares its domain context and ADR locations. A single-context repository commonly uses `CONTEXT.md` and `docs/adr/`; multi-context repositories may add context-local equivalents.

Read domain terms and relevant ADRs before changing language, boundaries, or architecture. Create files lazily only when a resolved term or accepted decision needs durable recording. Use the templates bundled with `domain-modeling`.

Keep one meaning per term within a context. Record aliases and deprecated language when they prevent ambiguity. ADRs capture accepted architectural decisions, their context, consequences, and supersession; they do not serve as speculative design diaries or duplicate the issue backlog.
