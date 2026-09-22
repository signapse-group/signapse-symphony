---
tracker:
  kind: github
  provider:
    repo: signapse-group/signapse-symphony
    project_owner: signapse-group
    project_number: 1
    issue_types:
      - Task
      - Bug
  required_labels: []
  dispatch_states:
    - Todo
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/signapse-symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/signapse-group/signapse-symphony .
    cp -R workflow/skills/* .codex/skills/
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.6-luna"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

You are working on assigned GitHub Project work item `{{ issue.identifier }}` in this repository.

{% if attempt %}
This is follow-up attempt #{{ attempt }}. Resume the existing workspace, branch, and pull request;
do not restart completed investigation or verification unless later changes invalidated it.
{% endif %}

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

Read the root `AGENTS.md`, load `$agent-execution-policy`, and invoke `$implement` for this work
item. The work item is the accepted implementation contract for this unattended run.

Use this tracker lifecycle:

- `Todo`: ready for autonomous work. Move it to `In Progress` before implementation.
- `In Progress`: implementation, verification, review fixes, and required CI are agent-owned.
- `In Review`: the current pull-request revision is ready for human review. Do not modify code or
  merge while the item remains in this state. Human-requested changes return it to `In Progress`.
- `Done`: terminal; do nothing and stop.

This run authorizes implementation, verification, commits, branch push, pull-request creation or
update, required CI follow-up, and GitHub Project state transitions from `Todo` to `In Progress`
and from `In Progress` to `In Review`. Move to `In Review` only after `$implement`'s checks,
independent review, pull-request evidence, and required CI are satisfied for the delivered revision.

Do not merge, deploy, mark the item `Done`, change product requirements, or create additional work
items unless the root `AGENTS.md` explicitly assigns that action. Stop only at the `In Review`
handoff boundary, `Done`, or a true external blocker with no meaningful independent work remaining.
