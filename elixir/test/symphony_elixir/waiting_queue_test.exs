defmodule SymphonyElixir.WaitingQueueTest do
  use SymphonyElixir.TestSupport

  setup do
    configure()
    :ok
  end

  test "waiting uses the same global, state, host and retry capacity gates as dispatch" do
    candidate = issue("queued")
    running = running_entry(issue("running"))

    scenarios = [
      {[], %{running: %{"running" => running}}},
      {[max_concurrent_agents: 3, max_concurrent_agents_by_state: %{"Todo" => 1}], %{running: %{"running" => running}}},
      {[max_concurrent_agents: 3, worker_ssh_hosts: ["worker"], worker_max_concurrent_agents_per_host: 1], %{running: %{"running" => Map.put(running, :worker_host, "worker")}}},
      {[], %{retry_attempts: %{"retry" => retry_entry()}, claimed: MapSet.new(["retry"])}},
      {[], %{tracker_tasks: %{make_ref() => tracker_task({:retry, "retry", 1, %{}})}}},
      {[], %{tracker_tasks: %{make_ref() => tracker_task({:dispatch, issue("admitting"), nil, %{}})}}}
    ]

    for {config, changes} <- scenarios do
      configure(config)
      state = Map.merge(cached([candidate]), changes)
      assert [row] = snapshot(state).waiting
      assert row.issue_id == candidate.id
      refute Orchestrator.should_dispatch_issue_for_test(candidate, state)
    end

    configure()
    assert snapshot(cached([candidate])).waiting == []
    assert Orchestrator.should_dispatch_issue_for_test(candidate, cached([candidate]))
  end

  test "waiting excludes dependencies, routing, state, ownership and pending admissions" do
    candidates = [
      issue("waiting"),
      %{issue("dependency") | admission_ready: false},
      %{issue("route") | labels: ["other"]},
      %{issue("inactive") | state: "In Progress"},
      %{issue("terminal") | state: "Done"},
      %{issue("invalid") | title: ""},
      %{issue("unroutable") | dispatchable: false},
      issue("claimed"),
      issue("running"),
      issue("blocked"),
      issue("retry"),
      issue("retry-reading"),
      issue("admitting")
    ]

    state = %{
      cached(candidates)
      | running: %{"running" => running_entry(issue("running"))},
        claimed: MapSet.new(["claimed"]),
        blocked: %{"blocked" => %{issue: issue("blocked")}},
        retry_attempts: %{"retry" => retry_entry()},
        tracker_tasks: %{
          make_ref() => tracker_task({:dispatch, issue("admitting"), nil, %{}}),
          make_ref() => tracker_task({:retry, "retry-reading", 1, %{}})
        }
    }

    assert Enum.map(snapshot(state).waiting, & &1.issue_id) == ["waiting"]
  end

  test "waiting follows dispatch order and exposes task details with observation time" do
    older = ~U[2026-01-01 00:00:00Z]
    newer = ~U[2026-01-02 00:00:00Z]

    candidates = [
      %{issue("last") | priority: nil, created_at: older},
      %{issue("newer") | priority: 2, created_at: newer},
      %{issue("older") | priority: 2, created_at: older},
      %{issue("first") | priority: 1, created_at: newer}
    ]

    state = hold_admission(cached(candidates))
    result = snapshot(state)
    assert Enum.map(result.waiting, & &1.issue_id) == ["first", "older", "newer", "last"]
    assert result.waiting_updated_at == state.candidate_snapshot.updated_at

    assert hd(result.waiting) == %{
             issue_id: "first",
             identifier: "QA-first",
             issue_url: "https://example.org/QA-first",
             title: "Task first",
             state: "Todo",
             priority: 1
           }
  end

  test "unobserved, recovering and changed tracker scopes do not show a slot queue" do
    state = hold_admission(cached([issue("queued")]))
    assert snapshot(%{state | candidate_snapshot: nil}).waiting_updated_at == nil
    assert snapshot(%{state | retry_restore_pending: true}).waiting == []

    configure(tracker_required_labels: ["other"])
    assert %{waiting: [], waiting_updated_at: nil} = snapshot(state)
    {:reply, _, updated} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    assert updated.candidate_snapshot == nil
  end

  test "poll errors invalidate observations and successful polls replace them" do
    state = hold_admission(cached([issue("old")]))

    capture_log(fn ->
      for result <- [
            %{running: {:ok, []}, blocked: {:ok, []}, candidates: {:error, :offline}},
            {:error, :offline}
          ] do
        updated = complete_read(state, {:poll, %{}, %{}}, result)
        assert updated.candidate_snapshot == nil
        assert %{waiting: [], waiting_updated_at: nil} = snapshot(updated)
      end
    end)

    result = %{running: {:ok, []}, blocked: {:ok, []}, candidates: {:ok, [issue("new")]}}
    updated = complete_read(state, {:poll, %{}, %{}}, result)
    assert Enum.map(snapshot(updated).waiting, & &1.issue_id) == ["new"]

    empty = complete_read(updated, {:poll, %{}, %{}}, %{result | candidates: {:ok, []}})
    assert empty.candidate_snapshot.issues == []
    assert snapshot(empty).waiting == []
    assert %DateTime{} = snapshot(empty).waiting_updated_at
  end

  test "skipped and failed dispatch refreshes remove the stale candidate" do
    candidate = issue("queued")
    state = hold_admission(cached([candidate, issue("other")]))

    capture_log(fn ->
      for result <- [
            {:skip, :missing},
            {:skip, %{candidate | state: "Done"}},
            {:error, :offline}
          ] do
        updated = complete_read(state, {:dispatch, candidate, nil, %{}}, result)
        assert Enum.map(updated.candidate_snapshot.issues, & &1.id) == ["other"]
        assert updated.running == %{}
      end
    end)
  end

  test "a refreshed candidate losing the capacity race stays waiting with current details" do
    candidate = issue("queued")
    state = hold_admission(cached([candidate]))
    refreshed = %{candidate | title: "Updated task", priority: 1}
    updated = complete_read(state, {:dispatch, candidate, nil, %{}}, {:ok, refreshed})
    assert [%{title: "Updated task", priority: 1}] = snapshot(updated).waiting
    assert updated.running == %{}

    blocked = %{refreshed | admission_ready: false}
    updated = complete_read(updated, {:dispatch, refreshed, nil, %{}}, {:ok, blocked})
    assert updated.candidate_snapshot.issues == [blocked]
    assert snapshot(updated).waiting == []
    assert updated.running == %{}
  end

  test "a live memory tracker poll publishes and replaces the waiting list" do
    pid = start_supervised!({Orchestrator, name: __MODULE__})
    await(pid, fn result -> result.waiting_updated_at != nil end)
    assert %{waiting: []} = GenServer.call(pid, :snapshot)

    :sys.replace_state(pid, &hold_admission/1)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("first")])
    send(pid, :run_poll_cycle)
    await(pid, fn result -> Enum.map(result.waiting, & &1.issue_id) == ["first"] end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("second")])
    send(pid, :run_poll_cycle)
    await(pid, fn result -> Enum.map(result.waiting, & &1.issue_id) == ["second"] end)
    assert :sys.get_state(pid).running == %{}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    stop_supervised!(Orchestrator)
    restarted = start_supervised!({Orchestrator, name: __MODULE__})
    assert restarted != pid
    assert GenServer.call(restarted, :snapshot).waiting == []
  end

  test "a released continuation claim cannot resurrect its cached pre-run candidate" do
    candidate = issue("finished")
    state = %{hold_admission(cached([candidate, issue("queued")])) | claimed: MapSet.new([candidate.id])}
    updated = complete_read(state, {:retry, candidate.id, 1, %{}}, {:ok, []})

    refute MapSet.member?(updated.claimed, candidate.id)
    assert Enum.map(updated.candidate_snapshot.issues, & &1.id) == ["queued"]
    assert Enum.map(snapshot(updated).waiting, & &1.issue_id) == ["queued"]
  end

  defp configure(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          tracker_required_labels: ["qa"],
          tracker_dispatch_states: ["Todo"],
          tracker_active_states: ["Todo", "In Progress"],
          max_concurrent_agents: 1,
          poll_interval_ms: 60_000
        ],
        overrides
      )
    )
  end

  defp issue(id) do
    %Issue{
      id: id,
      identifier: "QA-#{id}",
      title: "Task #{id}",
      state: "Todo",
      url: "https://example.org/QA-#{id}",
      labels: ["qa"],
      dispatchable: true
    }
  end

  defp cached(issues) do
    %Orchestrator.State{
      retry_restore_pending: false,
      max_concurrent_agents: Config.settings!().agent.max_concurrent_agents,
      candidate_snapshot: %{tracker: Config.settings!().tracker, issues: issues, updated_at: DateTime.utc_now()}
    }
  end

  defp snapshot(state) do
    {:reply, result, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    result
  end

  defp tracker_task(purpose), do: %{purpose: purpose, tracker: Config.settings!().tracker}

  defp hold_admission(state) do
    %{state | tracker_tasks: %{make_ref() => tracker_task({:dispatch, issue("admitting"), nil, %{}})}}
  end

  defp complete_read(state, purpose, result) do
    ref = make_ref()
    state = %{state | tracker_tasks: Map.put(state.tracker_tasks, ref, tracker_task(purpose))}
    {:noreply, updated} = Orchestrator.handle_info({ref, result}, state)
    if updated.tick_timer_ref, do: Process.cancel_timer(updated.tick_timer_ref)
    updated
  end

  defp running_entry(issue) do
    %{
      issue: issue,
      identifier: issue.identifier,
      pid: self(),
      session_id: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      started_at: DateTime.utc_now(),
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil
    }
  end

  defp retry_entry do
    %{attempt: 1, due_at_ms: System.monotonic_time(:millisecond) + 60_000, identifier: "QA-retry", error: "retry"}
  end

  defp await(pid, predicate, remaining \\ 100)

  defp await(_pid, _predicate, 0), do: flunk("waiting queue did not settle")

  defp await(pid, predicate, remaining) do
    result = GenServer.call(pid, :snapshot)

    if predicate.(result) do
      result
    else
      Process.sleep(10)
      await(pid, predicate, remaining - 1)
    end
  end
end
