# Grouped browser lease

FE CLI, QA CLI and QA Playwright MCP share the existing host lock inode at
`/opt/apps/symphony/runtime/locks/signapse-ui-integration.lock`.

| Entry point | Browser and web-server lifecycle |
| --- | --- |
| FE `runtime/run-fe-browser` | Existing `managed_temp.py` invokes the lease helper, which supervises `pnpm test:browser` and descendants. |
| QA `runtime/run-qa-browser` | Existing launcher invokes `qa-account-pool.py`, which reserves the browser before account, environment and slot locks. Any partial acquisition releases its locks in reverse before sleeping. |
| QA `runtime/ops/qa-playwright-mcp-20261112-CmsvYqQl/qa-codex` | Existing launcher selects its sibling `playwright-mcp`. The pinned Playwright 1.63.0 Test Agents preload acquires before global setup starts configured web servers. It releases after worker stop and global teardown, including `browser_close` and normal disposal. |

Telegram's existing account-first path makes both lock attempts with
`flock -n`. A failed attempt terminates without waiting for the browser lock.
Landing uses the same existing inode for its regular exclusive flock.
Landing and Telegram check the kernel lock. The durable owner record is
checked by FE and QA admission when the kernel holder exits unexpectedly.

FE and QA CLI return exit `73` and write
`resource_busy: host browser slot occupied; retry_after_seconds=30` before
launching heavy work. QA MCP returns the same text in a tool error. Wait at
least 30 seconds before retrying. This is a wrapper result. Symphony's
app-server retry queue receives process-level outcomes through its own
protocol.

The owner record under `runtime/locks/browser-lease` is written before launch.
If a launcher dies or cleanup fails, admission checks the recorded Symphony
session cgroup and refuses work until it is empty. Clean FE and QA CLI
release reaps child processes even if they create new process groups. Managed
sessions use the unique systemd session cgroup for SIGKILL containment. Manual
CLI sessions outside managed cgroups use the inherited flock and process-group
fence, which can follow only the original group if the supervisor is killed.
MCP requires the managed cgroup and can write only the browser lease state,
workspace and its existing validated evidence mounts.

## Install and verify

Stage the two reviewed revisions with `git archive`, preserving Linux line
endings. Pause and drain FE, QA and Landing through the existing control flow
before switching wrapper versions. Run as the owner of the host lock. Keep
the current stable QA harness deployment pinned to QA main
`484641caa232674fcc4f5ab0bd5d985bf4775720` using the QA source rollout.

```sh
python3 scripts/install_grouped_browser.py apply "$symphony_stage" "$qa_stage" "$backup" \
  --symphony-sha "$symphony_sha" --qa-sha "$qa_sha"
python3 scripts/install_grouped_browser.py verify "$backup"
```

Use a new private backup directory per release. A repeat apply with the same
backup verifies the existing install. The installer records source revisions,
file hashes, modes and the lock device and inode. It uses the host lock while
installing the following files.

| Staged source | Destination below `/opt/apps/symphony/runtime` | Mode |
| --- | --- | --- |
| QA `scripts/runtime/browser_lease.py` | `browser_lease.py` | `0750` |
| QA `scripts/runtime/qa-account-pool.py` | `qa-account-pool.py` | `0755` |
| Symphony `ops/grouped/run-fe-browser` | `run-fe-browser` | `0700` |
| Symphony `ops/grouped/playwright-browser-lease.cjs` | `ops/qa-playwright-mcp-20261112-CmsvYqQl/playwright-browser-lease.cjs` | `0640` |
| Symphony `ops/grouped/playwright-mcp` | `ops/qa-playwright-mcp-20261112-CmsvYqQl/playwright-mcp` | `0750` |

Run the technical fixture from a dedicated QA workspace and managed
session. While a fixture `planner_setup_page` is paused, a second heavy
caller should return the busy result and an idle MCP client should still be
able to initialize. After `browser_close`, check that the fixture web server
has stopped and that a new caller can acquire. On launcher death, check
`cgroup.events` for the recorded session before reconciling a stale owner file.

## Rollback

Pause and drain the same profiles and verify no browser session or recorded
owner cgroup remains active. Use the installer from the candidate revision.

```sh
python3 scripts/install_grouped_browser.py rollback "$backup"
```

The installer verifies the backup and restores the previous wrapper bytes
and modes under the same lock. The lock inode and owner-state directory are
kept. Restore the previously recorded QA harness revision if it was updated
during rollout.
