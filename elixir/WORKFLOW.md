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
    - Ready
  active_states:
    - Ready
    - In progress
  review_state: In review
  terminal_states:
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/signapse-symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/signapse-group/signapse-symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-6-luna"' --config model_reasoning_effort=max app-server
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

Read the root `AGENTS.md` and relevant directory instructions. The work item is the accepted
implementation contract for this unattended run.

Implement and deliver this work item as follows:

1. Read the current issue, comments, relevant references, and repository code. Inspect existing
   changes before editing; preserve work owned by others. Resume one branch and PR per deliverable.
2. Implement the smallest change that satisfies the issue. Run focused checks while iterating and
   `make -C elixir all` before handoff. Follow `elixir/AGENTS.md` for review and coding standards.
3. Have an independent reviewer check contract coverage and correctness. Resolve blocking findings
   and reverify affected behavior.
4. Create or update a PR targeting the default branch, following `.github/pull_request_template.md`.
   Include a closing reference to the assigned issue and verify `closingIssuesReferences`.
5. Resolve required `make-all` and `pr-description-lint` CI for the delivered revision. Record the
   PR URL, verified commit, contract coverage, checks/results, review results, and remaining
   nonblocking findings in one agent-owned handoff comment on the issue.
6. Move to `In review` only after required checks, review, and CI pass for the delivered revision.
   A maintainer reviews and merges; the Project's `Item closed` workflow moves the issue to `Done`.
   Verify that this Project workflow is enabled before handoff.

Use this tracker lifecycle:

- `Open`: not ready for autonomous work; do not dispatch it.
- `Ready`: ready for autonomous work. Move it to `In progress` before implementation.
- `In progress`: implementation, verification, review fixes, and required CI are agent-owned.
- `In review`: human handoff; do not modify code while the item remains in this state. Human-requested changes return it to `In progress`.
- `Blocked`: use only when material input or access is required and no meaningful independent work remains.
- `Done`: terminal; do nothing and stop.

This run authorizes implementation, verification, commits, branch push, pull-request creation or
update, required CI follow-up, and creating or updating this agent's blocker comments on the assigned
issue. Authorized GitHub Project state transitions are `Ready` to `In progress`, `In progress` to
`Blocked` after the blocker comment requirements below are met, and `In progress` to `In review`
after the handoff requirements above are met.

For blockers, investigate the missing input or access and finish meaningful independent work first.
Create or update this agent's comment on the issue with the reason, what was checked, the specific
human action needed, and the condition for resuming in `Ready`. Read back the saved comment before
moving to `Blocked`, then verify the status. If either operation fails, report the unconfirmed step;
do not claim it succeeded or change status without a verified comment.

After resolving the blocker, the human records the resolution on the issue and moves it from
`Blocked` to `Ready`. On resume, reread the issue and comments and verify the blocker is resolved
before continuing the same branch/PR.
If the issue returns to `Ready` without the required input, move it to `In progress`, update and
verify the existing blocker comment, then move it back to `Blocked` using the same sequence.

Do not merge, deploy, mark the item `Done`, change product requirements, or create additional work
items unless the root `AGENTS.md` explicitly assigns that action. Stop only at the `In review`
handoff boundary, `Done`, or a true external blocker with no meaningful independent work remaining.
