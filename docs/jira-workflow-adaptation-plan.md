# Jira workflow adaptation plan

Re-surveyed: 2026-10-06. This replaces the 2026-10-05 plan after removal of the shared execution skills. Code/documentation implementation was authorized on 2026-10-06. Installed runtime updates, live Jira writes and BE/FE changes are explicitly deferred.

## Scope and ownership

Upgrade Symphony's existing Jira runtime support first; update the BE/FE consuming workflows afterward, as confirmed by the user. Symphony supplies polling, selection, workspace/agent scheduling, recovery and the native `jira_rest` tool. Each consuming repository supplies its own implementation instructions and execution prompt in `AGENTS.md` / `WORKFLOW.md`; any skills are optional and repository-owned.

The deliverable is one coherent Symphony runtime change with regression checks and configuration documentation. It does not rebuild/distribute execution skills. Migrating the worker for development of Symphony itself remains separate; its current GitHub execution entrypoint is not the Jira consumer template.

| Responsibility | Owner after adaptation |
| --- | --- |
| Hierarchy, native lifecycle, routing map and human acceptance | Planning/coordinator |
| Structural eligibility, polling, dependencies at admission, reconciliation, retries and workspace safety | Symphony runtime |
| Reading the live contract, implementation, checks/review, status writes and delivery comments | Agent following the consuming repository's prompt |
| PR requirements, deployment applicability and output-specific handoff | Consuming repository and designated human owners |
| Jira transitions and most-recent-status resume conditions | Jira native workflow; coordinator resolves blockers and resumes work |

The runtime should not acquire a second implementation policy or automatically complete parent issues. Existing `jira_rest` is a general native tool governed by account permissions; prompt rules are not API permission enforcement.

## Survey baseline

- Symphony HEAD remains `77f8c822846a65dbe99a7e9ab61d3f4e9ee5838c`. The working tree includes the user's removal of the entire `workflow/` package plus changes to root instructions/readme, Elixir readme/prompt and `core_test.exs`. There are no working-tree changes to `elixir/lib/`, `SPEC.md` or CI. This plan uses the current working tree, not HEAD alone, and preserves those user changes.
- [AGENTS.md](../AGENTS.md) now defines Symphony as the runtime owner. The completion gate is `make -C elixir all`; required CI remains `make-all` and `pr-description-lint`.
- [README](../README.md) and [Elixir guide](../elixir/README.md) assign instructions, prompts and optional skills to consumers. [The self-execution prompt](../elixir/WORKFLOW.md) now contains its own GitHub implementation/review/handoff instructions and no longer copies a skills package into workspaces. The corresponding core assertions were updated by the user.
- Remaining `.codex/skills/` entries are repository operation skills (commit/push/pull/land/release/debug/linear), not a required runtime execution package. Searches of runtime, instructions, CI and these entries found no remaining invocation of the removed package; the README explicitly describes its independence.
- Planning HEAD is `cbdee596cd364e97ceeeb33a81e76f4c12c0e573`, with local changes to nine planning/issue-policy files. The current [execution workflow](../../signapse-planing/workflow/project-execution-workflow.md), [tracker policy](../../signapse-planing/workflow/issue-tracker.md) and [Subtask format](../../signapse-planing/workflow/issue-types/subtask.md) define the target. Their Symphony ownership/package references still describe shared skills and need a later documentation correction; their Jira lifecycle is the target contract. Sibling links require the Planning checkout.
- BE HEAD is `dd526971045570ded14ba0081c14971fa70f7ebc`; FE HEAD is `393bdcc49b43af243350e3ee887e8b55a54c14eb`. Both local checkouts are clean. Their `WORKFLOW.md` files still select GitHub Task/Bug work, invoke the removed execution skills and use merge/Item-closed completion. Updating those consumers remains later work.
- This re-survey read source, tests, instructions and workflow/configuration. It did not execute runtime tests or reverify live Jira. The Jira observations from 2026-10-05 are historical evidence only; recheck fields/types/transitions, runtime account and installed version before activation.

## Target execution profile

Planning requires autonomous workers to receive native **Subtasks** under Story, Task or Bug, with exactly one routing label identifying the repository. Parent Ready is insufficient to dispatch a worker. Title prefixes and assignees do not replace routing.

| Routing label | Repository |
| --- | --- |
| `route-backend` | `signapse-group/signapse` |
| `route-frontend` | `signapse-group/signapse-ui` |
| `route-quality-assurance` | `signapse-group/signapse-qa` |
| `route-mdg` | `signapse-group/signapse-mdg` |
| `route-landing` | `signapse-group/signapse-landing` |

Use one fixed repository/clone hook and workspace root per worker. Keep the label set in workflow configuration, not a Signapse constant in the scheduler. Ordinary business labels may coexist; missing or conflicting routes stay unclaimed with a diagnostic.

| Native Subtask status | Intended behavior |
| --- | --- |
| Open | Outside dispatch. |
| Ready | Coordinator-authorized initial queue. Revalidate eligibility; the agent enters Progress before implementation. |
| Progress | Execute/resume the same authorized operation and output. |
| In Review | Stop execution; coordinator/reviewer handles acceptance. Feedback returns to Progress. |
| Blocked | Stop execution. Resume to the actual pre-Blocked state through Jira's native rule. |
| Done | Terminal; coordinator completes the operation after its applicable delivery gate. |

Proposed configuration uses existing `dispatch_states: [Ready, Progress]`, `active_states: [Ready, Progress]`, `review_state: In Review` and `terminal_states: [Done]`. Progress discovery handles restart, review return and Blocked-to-Progress resume; it is continuation, not initial approval. Blocked-to-In Review remains idle.

The source now supports `provider.issue_types` and `provider.routing_labels`, reusing the existing `provider` map and `required_labels` for the worker's own route. Validate the configured type/route contract instead of silently widening a malformed profile to the entire project. Existing unprofiled Jira usage and other tracker adapters retain their supported behavior. The installed runtime does not acquire these capabilities until a later authorized update.

## Runtime gaps and minimum changes

| Gap verified in current source | Minimum adaptation |
| --- | --- |
| [Jira client](../elixir/lib/symphony_elixir/jira/client.ex) queries project/status only and omits issue type and parent from requested fields. | Narrow candidate JQL by configured type and worker route; request type/parent and validate returned native metadata. Subtask profile requires a valid parent. Revalidate from current data before spawning. |
| [Issue.routable?/2](../elixir/lib/symphony_elixir/tracker/issue.ex) checks all required labels, without rejecting multiple routes. | Check exactly one recognized route in Jira normalization/profile validation and its match to the configured worker. Reuse the generic label check; avoid a second routing system. |
| Readable by-ID records currently carry neither type nor parent. | Carry minimal non-secret identifiers in existing `native_ref` where appropriate. Keep changed-type/route records visible but ineligible so reconciliation can stop them; do not misreport them as API errors. |
| Ready-only polling misses unclaimed Progress work. | First prove the `[Ready, Progress]` profile through existing scheduler/runner seams. Retain current claims, refresh, retries and workspace reuse; add scheduler code only if a test demonstrates a missing behavior. |
| Jira gates dependencies in the `new` status category and compares blocker names with worker terminal states. | Check dependencies before initial dispatch and resumed operation; use Jira blocker completion/category so Done/Closed can satisfy a native dependency and Resolved cannot. Unknown/unreadable blockers remain unsatisfied. Keep this admission check distinct from ongoing routing so a dependency change does not blindly terminate independent in-flight work. |
| Terminal cleanup reads configured terminal states project-wide; running reconciliation handles terminal state before routing. | Scope startup cleanup and verify terminal/ownership-change ordering. Stop changed-route/type work without removing another repository's workspace; preserve recorded workspace ownership and conservative behavior on refresh errors. |
| ADF conversion discards marked hyperlink destinations, and normalized context lacks parent. | Expose parent/type identifiers to the prompt and preserve actionable reference URLs. The agent can fetch live parent/comments/raw ADF through existing `jira_rest`; do not eagerly load every contract/comment on every poll. |

The [tracker boundary](../elixir/lib/symphony_elixir/tracker.ex) already supports Jira and binds tools/auth to a session. Preserve that boundary. Status mutations remain agent-side native operations; do not introduce scheduler-owned Ready/Progress/Done transitions or a workflow engine.

## Implementation order

These are sequential parts of one deliverable, not tickets split by layer. Tests accompany their behavior changes.

| Step | Output | Required evidence |
| --- | --- | --- |
| 1. Selection and context | Validated Jira type/routing configuration; narrowed search; native type/parent context; by-ID revalidation and route diagnostics. Main files: `jira/client.ex`, `jira/adapter.ex` and their tests. | Parents, zero/two routes and wrong-repository tickets never start; a valid routed Subtask qualifies. Pagination, project scope, malformed data and generic Jira behavior remain correct. |
| 2. Admission and recovery | Dependency admission separated from ongoing routing where needed; Progress discovery; correct startup/retry/continuation/terminal cleanup. Touch `tracker/issue.ex`, scheduler or runner only at the demonstrated seam. | Real scheduler/runner tests prove restart/review/resume, one worker per issue, changed type/route, unknown dependencies and API failure behavior. No wrong-repository cleanup or unnecessary recreation of output. |
| 3. Consumer documentation | Update the Jira sections of `elixir/README.md` and affected SPEC semantics; provide a repository-owned Jira configuration/prompt example in the guide. Refresh introductory setup wording that currently assumes GitHub. | Example names supported keys and uses Jira-native states, `jira_rest`, live contract reads and explicit permissions/handoff. It works without a shared skills installation. The self-execution GitHub prompt remains consistent with its own repository policy. |
| 4. Full verification | Review the coherent runtime/docs change and complete repository gates. | Targeted tests and `make -C elixir all` pass; required `make-all` and `pr-description-lint` CI pass on the delivered revision. Follow the repository PR template and applicable review instructions. |
| 5. Controlled runtime validation | Validate the installed revision and disposable Subtask profile with an explicitly authorized canary. | Record account/route, issue, clone destination, revision, workspace recovery, transitions and handoff. Test Ready → Progress → In Review, review return and native blocker resume; coordinator retains Done. |

The documentation example is onboarding guidance, not a new mandatory package. It must distinguish runtime enforcement from instructions for the agent:

- Read the assigned Subtask and live parent requirements, relevant comments and references at start/resume/handoff; check Deliverable agrees with the repository. Required missing context blocks dependent work.
- Use `jira_rest` and current available transitions; record/read back the agent's blocker comment before Blocked. The coordinator records resolution and resumes to the previous status; a status change alone does not prove the blocker is resolved.
- Follow repository checks/review and operation-specific outputs. Include the Jira Subtask key in a PR title when a PR is required; maintain one agent-owned delivery comment without overwriting human content. Coordinator owns Done and parent acceptance; merge is not Jira completion.

These rules belong in each consumer's prompt when that repository migrates. Dev deployment evidence applies when the deliverable requires it. QA Generate and QA Execute/Retest have different handoff evidence; a completed QA run can report product Fail, whereas required unexecuted scope remains Blocked. The runtime should not encode those operation-specific business gates.

## Verification and completion

Use existing test files and observable seams: `jira_adapter_test.exs`, `workspace_and_config_test.exs`, `core_test.exs` and affected prompt/tool tests. Add focused regressions for Ready parents, exclusive routes, type/parent metadata, stale revalidation, admission versus continuation, scoped cleanup and Progress recovery. Existing other-adapter coverage must still pass.

Keep the existing opt-in [Jira live test](../elixir/test/symphony_elixir/jira_live_e2e_test.exs) as generic native-tool evidence: it currently creates a non-Subtask and asks the agent to finish a terminal transition. Add a scoped Subtask/handoff scenario for the new profile; that generic test alone does not prove Planning's coordinator-owned completion.

Required software gate: focused `mix test` under `elixir`, then `make -C elixir all`, repository-required review and required CI. There is no shared-package or skill-validator gate after the user's removal.

Acceptance requires:

1. Only an authorized, structurally valid Subtask in the worker's repository is admitted; parent status, title prefix or assignee cannot bypass type/route checks.
2. Ready starts initially; Progress resumes existing work; In Review/Blocked remain idle; Done is terminal. Route/type changes stop further work with safe workspace handling.
3. Dependencies are rechecked for admission/resume, references are usable, and unknown metadata or API failure never widens execution scope.
4. The installed canary runs without shared execution skills and demonstrates the configuration and agent prompt boundary. No automatic parent acceptance or coordinator-owned Done is added to the runtime.

Software readiness is the reviewed runtime/docs revision with passing required checks/CI. Operational readiness additionally requires installed-version/account validation and the authorized canary. The current request implements repository code/documentation only; live validation is deferred.

## Implementation record — 2026-10-06

- Added Jira type/exclusive-route configuration, native Subtask/parent validation, scoped candidate/terminal search, changed-ownership refresh and parent/reference context.
- Added adapter `admission_ready` with a compatible default for other trackers. Routed Jira dependencies gate initial/retry admission without interrupting ongoing work. Unknown/malformed dependencies remain unsatisfied.
- Protected running, blocked, retry and startup cleanup against changed routing/type ownership. Existing Progress polling now has an OTP-process regression covering restart, review return and blocker resume while creating one workspace.
- Added the repository-owned Jira onboarding/configuration/prompt example to the Elixir guide and updated the SPEC. Preserved the user's removal of the shared skills package and the GitHub self-execution prompt.
- Validation and installed-runtime rollout are recorded separately; no canary, deployment, ticket changes or consumer-repository updates occur in this code-only request.

### Local verification

- Focused Jira/scheduler/config tests: 125 tests passed before the final adversarial malformed-link check.
- Final `make -C elixir all`: passed in an isolated Elixir 1.19.5 / OTP 28 Linux container using the current working-tree sources. It completed build, format, specs/Credo lint, coverage and Dialyzer: 311 tests, zero failures, six opt-in live tests skipped; the configured coverage gate reached 100%; Dialyzer reported zero errors.
- The test copy normalized Windows checkout CRLF sources and snapshot fixtures to Linux LF without changing the repository's snapshot fixtures or application logic. Timer tests now use the memory tracker to avoid unrelated external polling during timing assertions.
- Documentation links/fences/UTF-8 and `git diff --check` passed. Existing dependency security advisories were reported by Hex; the dependency lock was not changed by this adaptation.
- Remote PR/CI, installed-runtime validation and Jira canary remain later delivery/rollout steps. No live Jira, FE/BE or deployed-worker configuration was changed.

## Later BE/FE migration

Hand off the verified Symphony revision, supported configuration example, permission requirements, canary record and known limitations. No skill package/version is part of this handoff.

BE and FE then update their own `WORKFLOW.md` and affected instructions: replace removed skill invocations with repository-owned execution rules, select Jira Subtask and the proper route, adopt Progress/In Review and previous-status resume, and apply the Jira delivery gate. Preserve their own checks/PR/deployment requirements. Correct Planning's stale Symphony package-ownership references in its owning documentation as part of coordinated follow-up.

Activate one repository at a time after stopping/draining its old GitHub worker and reconciling in-flight work. Verify the actual account, clone destination and handoff before general dispatch. Rollback stops the new worker while retaining workspaces/branches/output and Jira history; coordinator reconciliation precedes reactivation of any old queue.

QA/MDG/LANDING onboarding and a Jira worker for Symphony's own development remain separate. No new route for Symphony, multi-repository dispatcher, custom Repository field, webhook service or bundled execution policy is required for this adaptation.
