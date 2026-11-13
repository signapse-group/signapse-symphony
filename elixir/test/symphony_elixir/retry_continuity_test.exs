defmodule SymphonyElixir.RetryContinuityTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{HostResources, Profile, RuntimeControl}

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

  test "a heartbeat failure and two pressured stalls share the durable pause threshold" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 1,
      codex_stall_timeout_ms: 1_000
    )

    supervisor = start_supervised!(Task.Supervisor)
    issue = %Issue{id: "mixed", identifier: "SIGN-MIXED", state: "In Progress"}
    state = %Orchestrator.State{codex_totals: %{}, task_supervisor: supervisor, retry_restore_pending: false}
    state = fail(state, issue, 0, :session_heartbeat_expired)
    first = state.retry_attempts[issue.id]

    :ets.new(HostResources, [:named_table, :protected])
    now = System.monotonic_time(:millisecond)

    samples =
      for i <- 0..3 do
        %{
          sampled_at_ms: now - i * 5_000,
          cgroup: "/user.slice",
          runtime_cgroup: "/user.slice/app.slice/symphony.service",
          memory_events_high: 4 - i,
          oom_kill: 0,
          memory_some_us: (4 - i) * 1_000_000,
          io_full_us: 0
        }
      end

    :ets.insert(HostResources, {:samples, samples})

    state = stall(state, issue)
    assert %{infrastructure_failures: 2, reason_code: "host_pressure_stall"} = state.retry_attempts[issue.id]
    assert {:ok, %{mode: :running}} = RuntimeControl.status()

    stale_samples = Enum.map(samples, &Map.update!(&1, :sampled_at_ms, fn timestamp -> timestamp - 11_000 end))
    :ets.insert(HostResources, {:samples, stale_samples})
    state = stall(state, issue)
    assert %{infrastructure_failures: 2, reason_code: "stalled"} = state.retry_attempts[issue.id]
    assert {:ok, %{mode: :running}} = RuntimeControl.status()
    assert {:ok, [%{"infrastructure_failures" => 2, "reason_code" => "stalled"}]} = RuntimeControl.pending_retries("fe")

    :ets.insert(HostResources, {:samples, samples})
    state = stall(state, issue)
    assert {:ok, %{mode: :paused, source: "infrastructure"}} = RuntimeControl.status()
    assert {:ok, [retry]} = RuntimeControl.pending_retries("fe")
    assert retry["reason_code"] == "host_pressure_stall"
    assert retry["retry_priority"] == first.retry_priority
    assert retry["infrastructure_failures"] == 0
    assert MapSet.member?(state.claimed, issue.id)
    cancel(state)
    Process.cancel_timer(state.tick_timer_ref)
  end

  @tag :tmp_dir
  test "grouped threshold pauses FE while QA can still acquire a turn", %{tmp_dir: root} do
    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProfileRegistry})
    fe = start_grouped_control("fe", root)
    qa = start_grouped_control("qa", root)

    issue = %Issue{id: "scoped", identifier: "SIGN-SCOPED", state: "In Progress"}

    state = %Orchestrator.State{
      profile_id: "fe",
      profile_snapshot: %{settings: Config.settings!()},
      codex_totals: %{}
    }

    assert {:ok, %{retry_generation: generation}} = RuntimeControl.status(fe)
    state = fail(state, issue, 2, :session_heartbeat_expired, nil, generation)

    assert {:ok, %{mode: :paused, source: "infrastructure"}} = RuntimeControl.status(fe)
    assert {:error, :runtime_paused} = RuntimeControl.acquire_turn(fe)
    assert {:ok, [%{"issue_id" => "scoped"}]} = RuntimeControl.pending_retries("fe", fe)
    assert {:ok, %{mode: :running}} = RuntimeControl.status(qa)
    assert {:ok, []} = RuntimeControl.pending_retries("qa", qa)
    assert {:ok, qa_turn} = RuntimeControl.acquire_turn(qa)
    assert {:ok, %{active_turns: 0}} = RuntimeControl.release_turn(qa_turn, qa)

    assert {:ok, %{resume_version: version}} = RuntimeControl.begin_resume(fe)

    assert {:ok, %{retry_generation: ^generation}} =
             RuntimeControl.complete_resume(version, {:error, :response_timeout}, fe)

    assert {:ok, %{resume_version: version}} = RuntimeControl.begin_resume(fe)

    assert {:ok, %{retry_generation: next_generation}} =
             RuntimeControl.complete_resume(version, {:ok, %{available?: true}}, fe)

    assert next_generation == generation + 1

    stale = %{issue_id: "stale-write", infrastructure_failures: 0, retry_generation: generation}
    assert :ok = RuntimeControl.pause_with_retry("fe", stale, "Stale pause", fe)
    assert {:ok, %{mode: :running}} = RuntimeControl.status(fe)
    state = fail(state, issue, 2, :session_heartbeat_expired, nil, generation)
    assert state.retry_attempts[issue.id].infrastructure_failures == 1
    assert {:ok, %{mode: :running}} = RuntimeControl.status(fe)
    cancel(state)
  end

  test "a successful turn clears the inherited infrastructure count in recovery storage" do
    issue = %Issue{id: "success", identifier: "SIGN-SUCCESS", state: "In Progress"}
    assert :ok = RuntimeControl.persist_retry("fe", %{issue_id: issue.id, infrastructure_failures: 2})

    entry = %{
      pid: self(),
      issue: issue,
      session_id: nil,
      retry_attempt: 3,
      retry_priority: 9,
      infrastructure_failures: 2
    }

    state = %Orchestrator.State{running: %{issue.id => entry}, codex_totals: %{}}
    update = %{event: :turn_completed, timestamp: DateTime.utc_now(), worker_pid: self()}

    assert {:noreply, state} = Orchestrator.handle_info({:codex_worker_update, issue.id, update}, state)
    assert state.running[issue.id].infrastructure_failures == 0

    assert {:ok, [%{"issue_id" => "success", "attempt" => 3, "retry_priority" => 9, "infrastructure_failures" => 0}]} =
             RuntimeControl.pending_retries("fe")
  end

  test "retry and infrastructure pause roll back together when the pause write fails" do
    issue = %Issue{id: "atomic", identifier: "SIGN-ATOMIC", state: "In Progress"}
    conn = :sys.get_state(RuntimeControl).conn

    assert :ok =
             Exqlite.Sqlite3.execute(conn, """
             CREATE TEMP TRIGGER reject_pause BEFORE UPDATE OF mode ON runtime_control
             WHEN NEW.source = 'infrastructure'
             BEGIN SELECT RAISE(ABORT, 'pause write failed'); END
             """)

    assert :ok = RuntimeControl.persist_retry("fe", %{issue_id: issue.id, infrastructure_failures: 2})
    state = fail(%Orchestrator.State{codex_totals: %{}}, issue, 2, :session_heartbeat_expired)
    assert {:ok, %{mode: :running}} = RuntimeControl.status()
    assert {:ok, [%{"infrastructure_failures" => 2}]} = RuntimeControl.pending_retries("fe")
    assert state.retry_attempts[issue.id][:pending_write] =~ "Infrastructure retry limit"

    supervisor = start_supervised!(Task.Supervisor)
    state = %{state | task_supervisor: supervisor, retry_restore_pending: false}
    assert :ok = Exqlite.Sqlite3.execute(conn, "DROP TRIGGER reject_pause")
    assert {:noreply, state} = Orchestrator.handle_info(:run_poll_cycle, state)
    state = drain_tracker_reads(state)
    assert {:ok, %{mode: :paused, source: "infrastructure"}} = RuntimeControl.status()
    assert {:ok, [%{"infrastructure_failures" => 0, "reason_code" => "session_heartbeat_expired"}]} = RuntimeControl.pending_retries("fe")
    refute Map.has_key?(state.retry_attempts[issue.id], :pending_write)
    cancel(state)
    Process.cancel_timer(state.tick_timer_ref)
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

  test "replaying an already committed threshold write does not pause an operator resume" do
    retry = %{issue_id: "replay", attempt: 4, infrastructure_failures: 0, reason_code: "session_heartbeat_expired"}
    assert :ok = RuntimeControl.pause_with_retry("fe", retry, "Infrastructure retry limit reached", RuntimeControl)
    assert {:ok, %{resume_version: version}} = RuntimeControl.begin_resume()
    assert {:ok, _} = RuntimeControl.complete_resume(version, {:ok, %{available?: true, summary: "test"}})
    assert :ok = RuntimeControl.pause_with_retry("fe", retry, "Infrastructure retry limit reached", RuntimeControl)
    assert {:ok, %{mode: :running, source: "resume"}} = RuntimeControl.status()
  end

  test "pending retry reserves the only slot against fresh tickets" do
    issue = %Issue{id: "new", identifier: "SIGN-NEW", title: "New work", state: "Todo", dispatchable: true}
    state = %Orchestrator.State{max_concurrent_agents: 1, retry_attempts: %{"old" => %{retry_priority: 1}}}
    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(issue, %{state | retry_attempts: %{}})
  end

  test "waiting for slots is hidden during a shared pause and returns after resume" do
    issue = %Issue{id: "waiting", identifier: "SIGN-WAITING", title: "Waiting work", state: "Todo", dispatchable: true}

    state = %Orchestrator.State{
      retry_restore_pending: false,
      candidate_snapshot: %{tracker: Config.settings!().tracker, issues: [issue], updated_at: DateTime.utc_now()},
      retry_attempts: %{
        "old" => %{attempt: 1, due_at_ms: System.monotonic_time(:millisecond) + 10_000}
      }
    }

    assert {:reply, %{waiting: [%{issue_id: "waiting"}]}, _} = Orchestrator.handle_call(:snapshot, nil, state)
    assert {:ok, _} = RuntimeControl.pause("test pause", "manual")
    {:reply, paused_snapshot, _} = Orchestrator.handle_call(:snapshot, nil, state)
    assert %{waiting: [], waiting_updated_at: %DateTime{}} = paused_snapshot
    assert {:ok, %{resume_version: version}} = RuntimeControl.begin_resume()
    assert {:ok, _} = RuntimeControl.complete_resume(version, {:ok, %{available?: true, summary: "test"}})
    assert {:reply, %{waiting: [%{issue_id: "waiting"}]}, _} = Orchestrator.handle_call(:snapshot, nil, state)
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

  defp fail(state, issue, count, reason, priority \\ nil, generation \\ nil) do
    cancel(state)
    ref = make_ref()

    entry = %{
      pid: self(),
      ref: ref,
      issue: issue,
      identifier: issue.identifier,
      started_at: DateTime.utc_now(),
      infrastructure_failures: count,
      retry_generation: generation,
      retry_priority: priority
    }

    state = %{state | running: %{issue.id => entry}, retry_attempts: %{}, claimed: MapSet.new([issue.id])}
    {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, state)
    state
  end

  defp stall(state, issue) do
    retry = state.retry_attempts[issue.id]
    cancel(state)
    if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)
    pid = spawn(fn -> Process.sleep(:infinity) end)

    entry = %{
      pid: pid,
      ref: Process.monitor(pid),
      issue: issue,
      identifier: issue.identifier,
      started_at: DateTime.add(DateTime.utc_now(), -12, :second),
      retry_attempt: retry.attempt,
      retry_priority: retry.retry_priority,
      infrastructure_failures: retry.infrastructure_failures
    }

    state = %{state | running: %{issue.id => entry}, retry_attempts: %{}}
    {:noreply, state} = Orchestrator.handle_info(:run_poll_cycle, state)
    state = drain_tracker_reads(state)
    refute Process.alive?(pid)
    state
  end

  defp cancel(state) do
    for {_id, retry} <- state.retry_attempts, do: Process.cancel_timer(retry.timer_ref)
  end

  defp start_grouped_control(id, root) do
    name = Profile.via(id, :runtime_control)
    opts = [path: Path.join(root, id <> ".sqlite3"), runtime_id: id, members: [id], name: name]
    start_supervised!(Supervisor.child_spec({RuntimeControl, opts}, id: name))
    assert {:ok, %{resume_version: version}} = RuntimeControl.begin_resume(name)
    quota = %{available?: true, summary: "test"}
    assert {:ok, %{mode: :running}} = RuntimeControl.complete_resume(version, {:ok, quota}, name)
    name
  end
end
