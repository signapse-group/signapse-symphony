# Symphony workflow configuration

Use this reference only when the consuming repository will be run by Symphony.

`WORKFLOW.md` has YAML front matter for Symphony runtime configuration and a Markdown/Liquid body used as the agent prompt. Derive every value from the target repository, its tracker, and its deployed Symphony environment. Consult the installed Symphony version's documentation or existing valid configuration for supported fields; do not assume one provider's schema applies to another.

The front matter must establish:

- tracker kind, provider scope, required labels when used, and dispatch/active/terminal states;
- polling interval and workspace root;
- clone/bootstrap hooks needed to produce a usable repository workspace;
- concurrency and turn limits;
- Codex command, approval policy, and sandbox/network settings supported by the deployed app-server.

Keep tokens and secrets in environment variables or an existing external credential helper. The clone/bootstrap path must also make the installed workflow skills available to Codex. A project-scoped installation committed in the repository satisfies this after clone; a global installation must be verified on every worker host.

Use this minimal prompt shape and adapt tracker terminology and allowed mutations to repository policy:

```markdown
You are working on assigned work item `{{ issue.identifier }}` in this repository.

Read the root `AGENTS.md`, load `$agent-execution-policy`, and invoke `$implement` for this work item. The work item is the accepted implementation contract for this unattended run.

Issue context:

- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- State: {{ issue.state }}
- URL: {{ issue.url }}
- Labels: {{ issue.labels }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

This run authorizes implementation, verification, commits, branch push, pull-request creation or update, required CI follow-up, and configured issue-state transitions through the repository's human-review handoff boundary. Continue from the existing workspace and pull request on later attempts. Do not merge or deploy unless `AGENTS.md` explicitly assigns that action for the current state.
```

Keep additional prompt instructions only when they express a repository-specific fact or a real unattended-runtime constraint. Do not duplicate the implementation, testing, review, or delivery procedure already owned by `$agent-execution-policy` and `$implement`.

Before writing, check these invariants:

- dispatch states select only work that is ready for autonomous implementation;
- active states keep intended continuation attempts running and exclude human-wait states;
- terminal states cannot be redispatched;
- the prompt's authorized state transitions match the tracker configuration and `AGENTS.md` delivery condition;
- `AGENTS.md` identifies this file as the Symphony runtime entrypoint without treating its unattended prompt as a rule for ordinary interactive sessions;
- the resulting YAML parses and contains no unresolved placeholder in a required runtime field.
