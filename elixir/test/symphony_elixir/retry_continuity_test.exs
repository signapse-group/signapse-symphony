defmodule SymphonyElixir.RetryContinuityTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.RuntimeControl

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_concurrent_agents: 1)
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, RuntimeControl)
    path = Path.join(System.tmp_dir!(), "retry-continuity-#{System.unique_integer([:positive])}.sqlite3")
    start_supervised!({RuntimeControl, path: path, runtime_id: "fe", members: ["fe"]})
    {:ok, %{resume_version: version}} = RuntimeControl.begin_resume()
    {:ok, _} = RuntimeControl.complete_resume(version, {:ok, %{available?: true, summary: "test"}})

    on_exit(fn ->
      Supervisor.restart_child(SymphonyElixir.Supervisor, RuntimeControl)
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    end)

    :ok
  end

  test "three consecutive lease failures pause only this control and persist the retry" do
    issue = %Issue{id: "active", identifier: "SIGN-ACTIVE", state: "In Progress"}
    state = %Orchestrator.State{codex_totals: %{}}

    state = fail(state, issue, 0, :session_heartbeat_expired)
    assert state.retry_attempts[issue.id].infrastructure_failures == 1
    priority = state.retry_attempts[issue.id].retry_priority
    assert {:ok, %{mode: :running}} = RuntimeControl.status()
    state = fail(state, issue, 1, :session_heartbeat_expired, priority)
    assert state.retry_attempts[issue.id].infrastructure_failures == 2
    assert {:ok, %{mode: :running}} = RuntimeControl.status()
    state = fail(state, issue, 2, :session_heartbeat_expired, priority)
    assert {:ok, %{mode: :paused, source: "infrastructure", reason: reason}} = RuntimeControl.status()
    assert reason =~ "SIGN-ACTIVE"
    assert state.retry_attempts[issue.id].retry_priority == priority
    assert {:ok, [retry]} = RuntimeControl.pending_retries("fe")
    assert retry["retry_priority"] == priority
    assert retry["infrastructure_failures"] == 0
    cancel(state)
  end

  test "a different failure resets the consecutive infrastructure count" do
    issue = %Issue{id: "reset", identifier: "SIGN-RESET", state: "In Progress"}
    state = fail(%Orchestrator.State{codex_totals: %{}}, issue, 2, :other_failure)
    assert state.retry_attempts[issue.id].infrastructure_failures == 0
    assert {:ok, %{mode: :running}} = RuntimeControl.status()
    cancel(state)
  end

  test "guard exit 75 reaches the scheduler as a typed heartbeat failure" do
    root = Path.join(System.tmp_dir!(), "heartbeat-exit-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    command = Path.join(root, "codex")
    File.write!(command, "#!/bin/sh\nexit 75\n")
    File.chmod!(command, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root, codex_command: command)
    issue = %Issue{id: "heartbeat-exit", identifier: "SIGN-HEARTBEAT", state: "Todo", title: "Heartbeat"}
    {worker, ref} = spawn_monitor(fn -> AgentRunner.run(issue) end)
    assert_receive {:DOWN, ^ref, :process, ^worker, :session_heartbeat_expired}, 2_000
  end

  test "pending retry reserves the only slot against fresh tickets" do
    issue = %Issue{id: "new", identifier: "SIGN-NEW", title: "New work", state: "Todo", dispatchable: true}
    state = %Orchestrator.State{max_concurrent_agents: 1, retry_attempts: %{"old" => %{retry_priority: 1}}}
    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(issue, %{state | retry_attempts: %{}})
  end

  test "later retry cannot steal a slot or increase its failure attempt while waiting" do
    issue = %Issue{id: "later", identifier: "SIGN-LATER", title: "Later work", state: "In Progress", dispatchable: true}
    ref = make_ref()
    metadata = %{retry_priority: 2, infrastructure_failures: 1}
    read = %{tracker: Config.settings!().tracker, purpose: {:retry, issue.id, 2, metadata}}

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{"first" => %{retry_priority: 1}},
      tracker_tasks: %{ref => read},
      retry_restore_pending: false
    }

    assert {:noreply, state} = Orchestrator.handle_info({ref, {:ok, [issue]}}, state)
    assert state.running == %{}
    assert state.retry_attempts[issue.id].attempt == 2
    assert state.retry_attempts[issue.id].infrastructure_failures == 1
    assert state.retry_attempts[issue.id].retry_priority == 2
    cancel(%{state | retry_attempts: Map.take(state.retry_attempts, [issue.id])})
  end

  defp fail(state, issue, count, reason, priority \\ nil) do
    cancel(state)
    ref = make_ref()

    entry = %{
      pid: self(),
      ref: ref,
      issue: issue,
      identifier: issue.identifier,
      started_at: DateTime.utc_now(),
      infrastructure_failures: count,
      retry_priority: priority
    }

    state = %{state | running: %{issue.id => entry}, retry_attempts: %{}, claimed: MapSet.new([issue.id])}
    {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, state)
    state
  end

  defp cancel(state) do
    for {_id, retry} <- state.retry_attempts, do: Process.cancel_timer(retry.timer_ref)
  end
end
