# Symphony workflow configuration

Use this reference whenever `$setup-workflow` configures a consuming repository. Invocation of that
skill already establishes that the repository will be run by Symphony.

`WORKFLOW.md` has YAML front matter for Symphony runtime configuration and a Markdown/Liquid body
used as the agent prompt. Derive repository-owned values from the target repository and tracker;
inherit deployment-owned values from the deployed Symphony profile. Consult the installed Symphony
version's documentation or existing valid configuration for supported fields; do not assume one
provider's schema applies to another.

The repository onboarding must establish:

- tracker kind, provider scope, required labels when used, and dispatch/active/terminal states;
- clone/bootstrap hooks needed to produce a usable repository workspace;
- the prompt and repository lifecycle boundary.

The deployed Symphony profile establishes workspace root, polling, concurrency and turn limits,
Codex command and model, approval policy, sandbox/network settings, credentials, and available host
tools. Copy or preserve these values when the workflow format requires them; do not make them new
repository onboarding decisions.

Keep tokens and secrets in environment variables or an existing external credential helper. The clone/bootstrap path must also make the installed workflow skills available to Codex. A project-scoped installation committed in the repository satisfies this after clone; a global installation must be verified on every worker host.

Treat `workspace.root` as a deployment-level location for per-issue workspaces. Inspect the
Symphony service environment or deployment configuration for its established value. Prefer an
environment-backed reference such as `$SYMPHONY_WORKSPACE_ROOT` in the workflow, and preserve that
reference when it already exists; do not replace it with a machine-specific absolute path or ask
the repository user to provide the resolved path again. Apply the same inheritance rule to polling,
concurrency, turn limits, Codex command/model, approval, and sandbox settings. When no deployed
profile is accessible, omit absent optional settings so the installed runtime uses its supported
defaults, and report that deployment compatibility remains unverified.

Derive ordinary bootstrap commands from the repository. For example, a committed `pnpm-lock.yaml`
supports `pnpm install --frozen-lockfile` without a separate permission question. Ask only when the
bootstrap would require credentials, destructive host changes, or a material choice the repository
does not settle. Repository requirements such as Node, pnpm, browser binaries, or system libraries
are inputs to the deployment; host installation remains outside `$setup-workflow`.

For the standard GitHub Projects v2 Agent Workflow profile, use these verified roles:

```yaml
tracker:
  kind: github
  provider:
    repo: owner/repository
    project_owner: owner
    project_number: 1
    issue_types: [Task, Bug]
  dispatch_states: [Ready]
  active_states: [Ready, In progress]
  review_state: In review
  terminal_states: [Done]
```

`Open` remains outside autonomous dispatch, `Blocked` remains outside active execution, and
`In review` is the human handoff boundary. Verify these exact option names against the target
Project's `Status` field. Verify that both `Task` and `Bug` occur in the Project's
`Issue.issueType.name` values before accepting the default filter. If either is absent, require an
explicit issue-type override. If the board differs, change only the mapping; preserve the roles.

Use this minimal prompt shape and adapt tracker terminology and allowed mutations to the
consuming repository's policy. Do not copy state names from this example into a target
repository: tracker-native names must come from that repository's configured board.

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

This run authorizes implementation, verification, commits, branch push, pull-request creation or update, required CI follow-up, and configured issue-state transitions through the repository's review handoff boundary. Continue from the existing workspace and pull request on later attempts. Do not merge or deploy unless `AGENTS.md` explicitly assigns that action for the current state.
```

Keep additional prompt instructions only when they express a repository-specific fact or a real unattended-runtime constraint. Do not duplicate the implementation, testing, review, or delivery procedure already owned by `$agent-execution-policy` and `$implement`.

Before writing, check these invariants:

- dispatch states select only work that is ready for autonomous implementation;
- active states keep intended continuation attempts running and exclude human-wait states;
- terminal states cannot be redispatched;
- the prompt's authorized state transitions match the tracker configuration and `AGENTS.md` delivery condition;
- the review handoff state is a non-terminal human-owned boundary and is excluded from
  `active_states` when Symphony should stop there;
- `AGENTS.md` identifies this file as the Symphony runtime entrypoint without treating its unattended prompt as a rule for ordinary interactive sessions;
- the resulting YAML parses and contains no unresolved placeholder in a required runtime field.
