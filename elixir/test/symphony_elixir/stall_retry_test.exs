defmodule SymphonyElixir.StallRetryTest do
  use SymphonyElixir.TestSupport

  test "two consecutive stalls dispatch fresh workers through retry timers without losing the workspace" do
    root = Path.join(System.tmp_dir!(), "symphony-stall-retry-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    codex = Path.join(root, "fake-codex")
    created = Path.join(root, "workspace-created")

    File.write!(codex, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '{"id":2,"result":{"thread":{"id":"thread-%s"}}}\\n' "$$" ;;
        *'"method":"turn/start"'*) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn"}}}' ;;
      esac
    done
    """)

    File.chmod!(codex, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      poll_interval_ms: 60_000,
      max_concurrent_agents: 1,
      codex_stall_timeout_ms: 1_000,
      codex_command: "#{codex} app-server",
      hook_after_create: "mkdir evidence; printf preserved > evidence/run.json; printf x >> '#{created}'"
    )

    issue = %Issue{
      id: "stall-retry",
      identifier: "SIGN-STALL-RETRY",
      title: "Preserve a stalled QA run",
      state: "In Progress",
      url: "https://example.org/issues/SIGN-STALL-RETRY",
      dispatchable: true
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    supervisor = start_supervised!(Task.Supervisor)
    server = start_supervised!({Orchestrator, name: __MODULE__.Server, task_supervisor: supervisor})
    initial = await_worker(server, supervisor, issue.id, 0)
    workspace = initial.workspace_path
    evidence = Path.join(workspace, "evidence/run.json")

    Enum.reduce(1..2, initial, fn attempt, previous ->
      monitor = Process.monitor(previous.pid)
      stale = DateTime.add(DateTime.utc_now(), -5, :second)

      :sys.replace_state(server, fn state ->
        entry = state.running[issue.id] |> Map.put(:last_codex_timestamp, stale)
        %{state | running: Map.put(state.running, issue.id, entry)}
      end)

      send(server, :tick)

      state = await_state(server, &Map.has_key?(&1.retry_attempts, issue.id))
      retry = state.retry_attempts[issue.id]
      assert retry.attempt == attempt
      assert retry.error =~ "stalled for "
      assert_receive {:DOWN, ^monitor, :process, _, _}, 1_000
      refute Process.alive?(previous.pid)
      assert state.running == %{}
      assert File.read!(evidence) == "preserved"
      remaining = retry.due_at_ms - System.monotonic_time(:millisecond)
      assert_in_delta remaining, 10_000 * attempt, 1_000

      # Deliver the real timer message now without waiting out the production backoff.
      assert is_integer(Process.cancel_timer(retry.timer_ref))
      Process.send_after(server, {:retry_issue, issue.id, retry.retry_token}, 0)
      replacement = await_worker(server, supervisor, issue.id, attempt)

      assert replacement.pid != previous.pid
      assert replacement.session_id != previous.session_id
      assert replacement.workspace_path == workspace
      assert File.read!(evidence) == "preserved"
      assert File.read!(created) == "x"

      send(server, {:retry_issue, issue.id, retry.retry_token})
      state = :sys.get_state(server)
      assert state.claimed == MapSet.new([issue.id])
      assert map_size(state.running) == 1
      assert state.running[issue.id].pid == replacement.pid
      assert state.retry_attempts == %{}
      assert Task.Supervisor.children(supervisor) == [replacement.pid]
      replacement
    end)
  end

  defp await_worker(server, supervisor, issue_id, attempt) do
    state =
      await_state(server, fn state ->
        case state.running[issue_id] do
          %{retry_attempt: ^attempt, turn_count: 1, session_id: session, workspace_path: path, pid: pid}
          when is_binary(session) and is_binary(path) ->
            state.tracker_tasks == %{} and Task.Supervisor.children(supervisor) == [pid]

          _ ->
            false
        end
      end)

    assert state.claimed == MapSet.new([issue_id])
    state.running[issue_id]
  end

  defp await_state(server, predicate, attempts \\ 300)
  defp await_state(_server, _predicate, 0), do: flunk("orchestrator did not reach the expected retry state")

  defp await_state(server, predicate, attempts) do
    state = :sys.get_state(server)

    if predicate.(state) do
      state
    else
      Process.sleep(10)
      await_state(server, predicate, attempts - 1)
    end
  end
end
