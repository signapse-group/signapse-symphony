defmodule SymphonyElixir.StartupRecoveryTest do
  use SymphonyElixir.TestSupport

  test "registration timeout cannot launch Codex or be replaced by an after-run hook error" do
    root = Path.join(System.tmp_dir!(), "symphony-prelaunch-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      codex_command: "touch #{root}/launched",
      hook_after_run: "touch #{root}/after-run"
    )

    receiver = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(receiver, :kill) end)
    issue = %Issue{id: "prelaunch", identifier: "SIGN-258", state: "Todo"}

    {worker, ref} =
      spawn_monitor(fn ->
        AgentRunner.run(issue, nil,
          on_session_process: fn session -> GenServer.call(receiver, {:register, session}, 20) end,
          on_after_run: fn -> exit(:would_replace_original_error) end
        )
      end)

    assert_receive {:DOWN, ^ref, :process, ^worker, {:session_not_started, {:exit, {:timeout, _}}}}, 2_000
    refute File.exists?(Path.join(root, "launched"))
    refute File.exists?(Path.join(root, "after-run"))
  end

  test "proven prelaunch failure retries even if the placeholder was held" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    {worker, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    issue = %Issue{id: "prelaunch", identifier: "SIGN-258", state: "Todo"}

    entry = %{
      pid: worker,
      ref: ref,
      issue: issue,
      identifier: issue.identifier,
      started_at: DateTime.utc_now(),
      session_process: %{port: nil, containment: nil},
      handoff_error: "persistence failed",
      workspace_path: "/preserved/workspace"
    }

    state = %Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), codex_totals: %{}}
    reason = {:session_not_started, {:exit, :registration_timeout}}
    assert {:noreply, recovered} = Orchestrator.handle_info({:DOWN, ref, :process, worker, reason}, state)
    assert recovered.running == %{}
    assert recovered.retry_attempts[issue.id].error =~ "registration_timeout"
    assert recovered.retry_attempts[issue.id].workspace_path == "/preserved/workspace"
    Process.cancel_timer(recovered.retry_attempts[issue.id].timer_ref)
  end

  test "external worker death with uncertain startup still retains ownership" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue = %Issue{id: "unknown", identifier: "SIGN-UNKNOWN", state: "Todo"}
    ref = make_ref()

    entry = %{
      pid: self(),
      ref: ref,
      issue: issue,
      identifier: issue.identifier,
      started_at: DateTime.utc_now(),
      session_process: %{port: nil, containment: nil}
    }

    state = %Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), codex_totals: %{}}
    assert {:noreply, held} = Orchestrator.handle_info({:DOWN, ref, :process, self(), :killed}, state)
    assert held.running[issue.id].handoff_error =~ "session_process_unknown"
    assert held.retry_attempts == %{}
  end

  test "only failures in the prelaunch callback carry proof that no process started" do
    root = Path.join(System.tmp_dir!(), "symphony-launch-proof-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root, codex_command: "cat")
    File.mkdir_p!(root <> "/issue")

    {worker, ref} =
      spawn_monitor(fn ->
        AppServer.start_session(root <> "/issue",
          on_started: fn session ->
            if is_nil(session.port), do: {:error, :persist_rejected}, else: :ok
          end
        )
      end)

    reason = {:session_not_started, {:error, {:badmatch, {:error, :persist_rejected}}}}
    assert_receive {:DOWN, ^ref, :process, ^worker, ^reason}, 1_000

    {worker, ref} =
      spawn_monitor(fn ->
        AppServer.start_session(root <> "/issue",
          on_started: fn session ->
            if is_port(session.port), do: exit(:failed_after_open), else: :ok
          end
        )
      end)

    assert_receive {:DOWN, ^ref, :process, ^worker, :failed_after_open}, 1_000
  end

  test "late registration from a dead worker is rejected" do
    {worker, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    state = %Orchestrator.State{running: %{"dead" => %{pid: worker}}}

    registration = {:session_process, "dead", worker, %{port: nil, containment: nil}}

    assert {:reply, {:error, :stale_worker}, ^state} =
             Orchestrator.handle_call(registration, {self(), make_ref()}, state)
  end

  test "slow polling leaves the mailbox responsive and coalesces refreshes" do
    {server, reader} = blocked_poll!()
    issue = %Issue{id: "active", identifier: "SIGN-ACTIVE", state: "Todo"}

    :sys.replace_state(server, fn state ->
      %{state | running: %{issue.id => %{pid: self(), issue: issue}}}
    end)

    # The registered worker is the server's process in this synthetic entry.
    assert :ok = GenServer.call(server, {:session_process, issue.id, server, %{port: nil, containment: nil}}, 500)
    assert %{coalesced: true} = GenServer.call(server, :request_refresh, 500)
    send(server, :run_poll_cycle)
    assert map_size(:sys.get_state(server).tracker_tasks) == 1
    send(reader, {:result, {:ok, []}})
    await_idle(server)
  end

  test "tracker task failure ends polling and allows the next refresh" do
    {server, reader} = blocked_poll!()
    Process.exit(reader, :kill)
    await_idle(server)
    GenServer.call(server, :request_refresh)
    assert_receive {:tracker_read, next_reader, :states}, 1_000
    send(next_reader, {:result, {:ok, []}})
    await_idle(server)
  end

  test "a delayed poll cannot reconcile a replacement worker using the old worker snapshot" do
    {server, reader} = blocked_poll!()
    send(reader, {:result, {:ok, []}})
    await_idle(server)
    old_worker = spawn(fn -> receive do: (:stop -> :ok) end)
    replacement = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      Process.exit(old_worker, :kill)
      Process.exit(replacement, :kill)
    end)

    issue = %Issue{id: "replaced", identifier: "SIGN-REPLACED", state: "Todo"}

    :sys.replace_state(server, fn state ->
      %{state | running: %{issue.id => %{pid: old_worker, ref: make_ref(), identifier: issue.identifier, issue: issue}}}
    end)

    send(server, :run_poll_cycle)
    assert_receive {:tracker_read, reader, {:ids, ["replaced"]}}, 1_000
    send(reader, {:result, {:ok, []}})
    assert_receive {:tracker_read, reader, :states}, 1_000
    :sys.replace_state(server, fn state -> put_in(state.running[issue.id].pid, replacement) end)
    send(reader, {:result, {:ok, []}})
    state = await_idle(server)
    assert state.running[issue.id].pid == replacement
    assert Process.alive?(replacement)
  end

  test "terminal admission refresh removes the recorded retry workspace" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    root = Path.join(System.tmp_dir!(), "symphony-terminal-admission-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)
    workspace = Path.join(root, "SIGN-TERMINAL")
    File.mkdir_p!(workspace)
    issue = %Issue{id: "terminal", identifier: "SIGN-TERMINAL", state: "Todo", title: "Terminal", dispatchable: true}
    metadata = %{workspace_path: workspace}
    ref = make_ref()
    read = %{tracker: Config.settings!().tracker, purpose: {:dispatch, issue, 1, metadata}}
    state = %Orchestrator.State{claimed: MapSet.new([issue.id]), tracker_tasks: %{ref => read}}
    assert {:noreply, state} = Orchestrator.handle_info({ref, {:skip, %{issue | state: "Done"}}}, state)
    refute File.dir?(workspace)
    refute MapSet.member?(state.claimed, issue.id)
  end

  test "a late retry result cannot release a replacement worker's claim" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue = %Issue{id: "retry", identifier: "SIGN-RETRY", state: "Todo"}
    ref = make_ref()
    read = %{tracker: Config.settings!().tracker, purpose: {:retry, issue.id, 1, %{}}}
    state = %Orchestrator.State{claimed: MapSet.new([issue.id]), running: %{issue.id => %{pid: self()}}, tracker_tasks: %{ref => read}}
    assert {:noreply, updated} = Orchestrator.handle_info({ref, {:ok, []}}, state)
    assert updated.claimed == state.claimed
    assert updated.running == state.running
    assert updated.tracker_tasks == %{}
  end

  test "admission results honor a lower concurrency limit and block workflow updates while pending" do
    root = Path.join(System.tmp_dir!(), "symphony-admission-limit-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 1,
      workspace_root: root,
      hook_before_run: "sleep 2; exit 1"
    )

    supervisor = start_supervised!(Task.Supervisor)
    first = %Issue{id: "first", identifier: "SIGN-FIRST", state: "Todo", title: "First", dispatchable: true}
    second = %{first | id: "second", identifier: "SIGN-SECOND"}
    first_ref = make_ref()
    second_ref = make_ref()

    reads =
      Map.new([{first_ref, first}, {second_ref, second}], fn {ref, issue} ->
        {ref, %{tracker: Config.settings!().tracker, purpose: {:dispatch, issue, nil, %{}}}}
      end)

    state = %Orchestrator.State{
      max_concurrent_agents: 2,
      task_supervisor: supervisor,
      tracker_tasks: reads,
      retry_restore_pending: false
    }

    assert {:reply, {:error, _}, ^state} = Orchestrator.handle_call(:workflow_update_ready, {self(), make_ref()}, state)
    assert {:noreply, state} = Orchestrator.handle_info({first_ref, {:ok, first}}, state)
    assert state.max_concurrent_agents == 1
    assert {:noreply, state} = Orchestrator.handle_info({second_ref, {:ok, second}}, state)
    assert map_size(state.running) == 1
    assert Map.has_key?(state.running, second.id)
  end

  defp blocked_poll! do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, __MODULE__.SlowTracker)
    Application.put_env(:symphony_elixir, :startup_test_owner, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :linear_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)

      Application.delete_env(:symphony_elixir, :startup_test_owner)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", poll_interval_ms: 60_000)
    supervisor = start_supervised!(Task.Supervisor)
    name = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
    server = start_supervised!({Orchestrator, name: name, task_supervisor: supervisor})
    assert_receive {:tracker_read, reader, :states}, 1_000
    {server, reader}
  end

  defp await_idle(server, remaining \\ 100)
  defp await_idle(_server, 0), do: flunk("tracker tasks did not finish")

  defp await_idle(server, remaining) do
    state = :sys.get_state(server)

    if map_size(state.tracker_tasks) == 0 and not state.poll_check_in_progress do
      state
    else
      Process.sleep(10)
      await_idle(server, remaining - 1)
    end
  end

  defmodule SlowTracker do
    def fetch_issues_by_states(states) do
      if "Todo" in states do
        send(Application.fetch_env!(:symphony_elixir, :startup_test_owner), {:tracker_read, self(), :states})
        receive do: ({:result, result} -> result)
      else
        {:ok, []}
      end
    end

    def fetch_issues_by_ids(ids) do
      send(Application.fetch_env!(:symphony_elixir, :startup_test_owner), {:tracker_read, self(), {:ids, ids}})
      receive do: ({:result, result} -> result)
    end
  end
end
