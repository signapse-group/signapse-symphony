defmodule SymphonyElixir.ReviewTaskTest do
  use SymphonyElixir.TestSupport

  test "review boundaries end the current task while Ready and Progress continue" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "Progress", "In Review"],
      tracker_review_state: "In Review"
    )

    for {before, after_state, result} <- [
          {"Ready", "Progress", :continue},
          {"Progress", "Ready", :continue},
          {"Progress", " in REVIEW ", :done},
          {"In Review", "PROGRESS", :done},
          {"In Review", " in review ", :continue}
        ] do
      issue = %Issue{id: "review-task", state: before, dispatchable: true}
      refreshed = %{issue | state: after_state}
      assert {^result, ^refreshed} = AgentRunner.continue_with_issue_for_test(issue, fn [_] -> {:ok, [refreshed]} end)
    end
  end

  test "an unset review boundary retains active-state continuation" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Progress", "In Review"]
    )

    issue = %Issue{id: "legacy-task", state: "Progress", dispatchable: true}
    refreshed = %{issue | state: "In Review"}
    assert {:continue, ^refreshed} = AgentRunner.continue_with_issue_for_test(issue, fn [_] -> {:ok, [refreshed]} end)
  end

  test "additional boundaries isolate survey, implementation and review sessions" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "Progress", "In Review"],
      tracker_review_state: "In Review",
      tracker_session_boundary_states: [" READY ", "In Review"]
    )

    for {before, after_state, result} <- [
          {"Ready", "Progress", :done},
          {"Progress", "Ready", :done},
          {"Ready", "In Review", :done},
          {"In Review", "Ready", :done},
          {"Progress", "In Review", :done},
          {"In Review", "Progress", :done},
          {"Ready", " ready ", :continue},
          {"Progress", " PROGRESS ", :continue},
          {"In Review", " in review ", :continue},
          {"Ready", "Blocked", :done}
        ] do
      issue = %Issue{id: "survey-task", state: before, dispatchable: true}
      refreshed = %{issue | state: after_state}
      assert {^result, ^refreshed} = AgentRunner.continue_with_issue_for_test(issue, fn [_] -> {:ok, [refreshed]} end)
    end
  end

  test "a survey boundary does not require a review boundary" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "Progress"],
      tracker_session_boundary_states: ["Ready"]
    )

    issue = %Issue{id: "survey-only", state: "Ready", dispatchable: true}
    refreshed = %{issue | state: "Progress"}
    assert {:done, ^refreshed} = AgentRunner.continue_with_issue_for_test(issue, fn [_] -> {:ok, [refreshed]} end)
  end

  test "session boundary configuration defaults off and rejects malformed states" do
    alias SymphonyElixir.Config.Schema

    assert {:ok, settings} = Schema.parse(%{})
    assert settings.tracker.session_boundary_states == []
    assert {:ok, settings} = Schema.parse(%{tracker: %{session_boundary_states: ["Ready"]}})
    assert settings.tracker.session_boundary_states == ["Ready"]

    for invalid <- ["Ready", [" "], [nil], [%{}]] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{tracker: %{session_boundary_states: invalid}})
      assert message =~ "tracker.session_boundary_states"
    end
  end

  test "workflow reload applies a newly configured survey boundary" do
    issue = %Issue{id: "reload-boundary", state: "Ready", dispatchable: true}
    refreshed = %{issue | state: "Progress"}
    fetcher = fn [_] -> {:ok, [refreshed]} end

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["Ready", "Progress"])
    assert {:continue, ^refreshed} = AgentRunner.continue_with_issue_for_test(issue, fetcher)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "Progress"],
      tracker_session_boundary_states: ["Ready"]
    )

    assert {:done, ^refreshed} = AgentRunner.continue_with_issue_for_test(issue, fetcher)
  end

  test "an unconfirmed boundary stop retains ownership until operator inspection" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "Progress", "In Review"],
      tracker_session_boundary_states: ["Ready"]
    )

    issue = %Issue{id: "claimed-survey", identifier: "SIGN-90003", state: "Ready", dispatchable: true}
    task_supervisor = start_supervised!(Task.Supervisor)
    {:ok, worker} = Task.Supervisor.start_child(task_supervisor, fn -> receive do: (:stop -> :ok) end)

    entry = %{pid: worker, ref: nil, identifier: issue.identifier, issue: issue, started_at: DateTime.utc_now()}
    state = %Orchestrator.State{task_supervisor: task_supervisor, running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), codex_totals: %{}}
    reconciled = Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Progress"}], state)

    assert reconciled.running[issue.id].issue.state == "Ready"
    assert reconciled.running[issue.id].handoff_error =~ "session_process_unknown"
    assert reconciled.running[issue.id].pid == worker
    assert MapSet.member?(reconciled.claimed, issue.id)
    assert Process.alive?(worker)
    assert Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Done"}], reconciled) == reconciled
  end

  for {before, next_phase} <- [{"Ready", "Progress"}, {"Progress", "In Review"}, {"In Review", "Progress"}],
      {transport, host} <- [{"local", nil}, {"ssh", System.get_env("SYMPHONY_TEST_SSH_HOST")}] do
    @before before
    @next_phase next_phase
    @host host
    @tag skip: transport == "ssh" and is_nil(host)
    test "#{transport} reconcile interrupts #{@before} → #{@next_phase} and dispatches a fresh thread" do
      {test_root, trace_file, codex_binary} = fake_codex_fixture!()
      File.write!(Path.join(test_root, "hold-turn"), "")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Ready", "Progress", "In Review"],
        tracker_review_state: "In Review",
        tracker_session_boundary_states: ["Ready"],
        worker_ssh_hosts: if(@host, do: [@host], else: []),
        workspace_root: Path.join(test_root, "workspaces"),
        hook_after_create: "printf preserved > output.txt",
        codex_command: "#{codex_binary} app-server",
        max_turns: 1,
        prompt: "{{ issue.state }} {{ issue.identifier }}"
      )

      issue = %Issue{id: "interrupt-survey", identifier: "SIGN-90004", title: "Phase handoff", state: @before, dispatchable: true}
      parent = self()
      supervisor = start_supervised!(Task.Supervisor)
      {:ok, worker} = Task.Supervisor.start_child(supervisor, fn -> AgentRunner.run(issue, parent, worker_host: @host) end)
      monitor = Process.monitor(worker)
      assert_receive {:worker_runtime_info, _, runtime}, 2_000
      assert_receive {:worker_runtime_info, _, %{session_process: _} = session_runtime}, 2_000
      assert_receive {:codex_worker_update, _, %{event: :session_started, thread_id: previous_thread}}, 2_000

      entry = %{pid: worker, ref: monitor, identifier: issue.identifier, issue: issue, started_at: DateTime.utc_now()}
      state = %Orchestrator.State{task_supervisor: supervisor, running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), codex_totals: %{}}
      {:noreply, state} = Orchestrator.handle_info({:worker_runtime_info, issue.id, runtime}, state)
      {:noreply, state} = Orchestrator.handle_info({:worker_runtime_info, issue.id, session_runtime}, state)
      independent_monitor = Process.monitor(worker)
      refreshed = %{issue | state: @next_phase}
      reconciled = Orchestrator.reconcile_issue_states_for_test([refreshed], state)

      assert_receive {:DOWN, ^independent_monitor, :process, ^worker, _}, 2_000
      refute Map.has_key?(reconciled.running, issue.id)
      assert MapSet.member?(reconciled.claimed, issue.id)
      assert File.read!(Path.join(runtime.workspace_path, "output.txt")) == "preserved"
      child_pid = test_root |> Path.join("child.pid") |> File.read!() |> String.trim()
      {status, _} = System.cmd("ps", ["-o", "stat=", "-p", child_pid])
      assert String.trim(status) == "" or String.starts_with?(String.trim(status), "Z")
      File.rm!(Path.join(test_root, "hold-turn"))
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [refreshed])
      retry = reconciled.retry_attempts[issue.id]
      dispatch_ready = %{reconciled | retry_restore_pending: false}
      retry_message = {:retry_issue, issue.id, retry.retry_token}
      assert {:noreply, dispatched} = Orchestrator.handle_info(retry_message, dispatch_ready)
      assert dispatched.running[issue.id].pid != worker
      assert_receive {:codex_worker_update, _, %{event: :session_started, thread_id: next_thread}}, 2_000
      assert previous_thread != next_thread
      assert turn_prompts(trace_messages(trace_file)) == ["#{@before} SIGN-90004", "#{@next_phase} SIGN-90004"]
      assert File.read!(Path.join(runtime.workspace_path, "output.txt")) == "preserved"
    end
  end

  test "late messages cannot update a replacement worker or its recovery" do
    issue = %Issue{id: "replacement", identifier: "SIGN-90005", state: "Progress"}
    supervisor = start_supervised!(Task.Supervisor)
    {:ok, old} = Task.Supervisor.start_child(supervisor, fn -> receive do: (:stop -> :ok) end)
    entry = %{pid: self(), identifier: issue.identifier, issue: issue, session_id: "new-thread", workspace_path: "new-workspace"}
    state = %Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}

    assert {:noreply, ^state} =
             Orchestrator.handle_info(
               {:worker_runtime_info, issue.id, %{worker_pid: old, workspace_path: "old-workspace"}},
               state
             )

    assert {:noreply, ^state} =
             Orchestrator.handle_info(
               {:codex_worker_update, issue.id, %{worker_pid: old, event: :session_started, timestamp: DateTime.utc_now(), session_id: "old-thread"}},
               state
             )

    assert {:noreply, ^state} =
             Orchestrator.handle_info(
               {:codex_worker_update, issue.id, %{event: :session_started, timestamp: DateTime.utc_now()}},
               state
             )
  end

  test "a child outside the session process group prevents confirmed stop" do
    {root, _, codex_binary} = fake_codex_fixture!()
    File.write!(Path.join(root, "detached-child"), "")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      tracker_session_boundary_states: ["Ready"],
      codex_command: codex_binary
    )

    assert {:ok, session} = AppServer.start_session(workspace)
    child_pid = root |> Path.join("child.pid") |> File.read!() |> String.trim()

    try do
      assert {:error, {:session_stop_unconfirmed, _}} = AppServer.stop_session(session)
    after
      System.cmd("kill", ["-KILL", child_pid])
      assert :ok = AppServer.stop_session(session)
    end
  end

  test "reconcile without configured boundaries retains active-state continuation" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["Ready", "Progress"])
    issue = %Issue{id: "legacy-reconcile", identifier: "SIGN-90006", state: "Ready", dispatchable: true}
    entry = %{pid: self(), issue: issue}
    state = %Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
    reconciled = Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Progress"}], state)
    assert reconciled.running[issue.id].issue.state == "Progress"
    assert reconciled.running[issue.id].pid == self()
    assert MapSet.member?(reconciled.claimed, issue.id)
  end

  test "durable handoff recovery pauses dispatch after orchestrator restart" do
    alias SymphonyElixir.RuntimeControl
    {root, _, _} = fake_codex_fixture!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      tracker_active_states: ["Ready", "Progress"],
      tracker_session_boundary_states: ["Ready"]
    )

    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, RuntimeControl)
    on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, RuntimeControl) end)
    start_supervised!({RuntimeControl, path: Path.join(root, "control.sqlite3"), runtime_id: "handoff-test"})
    assert {:ok, %{version: version}} = RuntimeControl.begin_resume()
    quota = {:ok, %{available?: true, summary: "test"}}
    assert {:ok, %{mode: :running}} = RuntimeControl.complete_resume(version, quota)

    supervisor = start_supervised!(Task.Supervisor)
    {:ok, worker} = Task.Supervisor.start_child(supervisor, fn -> receive do: (:stop -> :ok) end)
    issue = %Issue{id: "handoff-restart", identifier: "SIGN-90007", state: "Ready", dispatchable: true}
    workspace = Path.join(root, issue.identifier)
    File.mkdir_p!(workspace)
    output = Path.join(workspace, "output.txt")
    File.write!(output, "uncommitted output")
    started_at = DateTime.utc_now()
    entry = %{pid: worker, ref: nil, identifier: issue.identifier, issue: issue, started_at: started_at}
    entry = Map.put(entry, :workspace_path, workspace)
    state = %Orchestrator.State{task_supervisor: supervisor, running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), codex_totals: %{}}
    held = Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Progress"}], state)
    assert held.running[issue.id].handoff_error =~ "session_process_unknown"
    assert {:ok, [record]} = RuntimeControl.pending_retries("handoff-test")
    assert record["error"] == "Phase boundary handoff requires operator confirmation"
    assert record["workspace_path"] == workspace
    Task.Supervisor.terminate_child(supervisor, worker)

    completed_issue = %{issue | id: "completed-boundary"}
    completed_ref = make_ref()
    completed_entry = %{entry | issue: completed_issue, pid: self(), ref: completed_ref}
    completed_state = %{state | running: %{completed_issue.id => completed_entry}, claimed: MapSet.new([completed_issue.id])}
    prepare = {:prepare_boundary, completed_issue.id, self()}
    assert {:reply, :ok, prepared} = Orchestrator.handle_call(prepare, {self(), make_ref()}, completed_state)
    assert prepared.running[completed_issue.id].boundary_completed
    close = {:session_closed, completed_issue.id, self()}
    assert {:reply, :ok, prepared} = Orchestrator.handle_call(close, {self(), make_ref()}, prepared)
    assert is_nil(prepared.running[completed_issue.id].session_process)

    assert {:reply, {:error, :stale_worker}, ^prepared} =
             Orchestrator.handle_call({:prepare_boundary, completed_issue.id, worker}, {self(), make_ref()}, prepared)

    completed_message = {:DOWN, completed_ref, :process, self(), :normal}
    assert {:noreply, completed} = Orchestrator.handle_info(completed_message, prepared)
    assert completed.retry_attempts[completed_issue.id].error == record["error"]
    assert {:ok, records} = RuntimeControl.pending_retries("handoff-test")
    assert Enum.all?(records, &(&1["error"] == record["error"]))

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Done"}])
    orchestrator = start_supervised!({Orchestrator, name: __MODULE__.RecoveryOrchestrator, task_supervisor: supervisor})
    assert {:ok, %{mode: :paused, source: "recovery"}} = RuntimeControl.status()
    send(orchestrator, :run_poll_cycle)
    restored = :sys.get_state(orchestrator)
    assert MapSet.member?(restored.claimed, issue.id)
    assert restored.running == %{}
    assert restored.retry_attempts[issue.id].workspace_path == workspace
    assert File.read!(output) == "uncommitted output"
    assert {:error, :runtime_paused} = RuntimeControl.acquire_turn()
    assert {:ok, %{version: resumed_version}} = RuntimeControl.begin_resume()
    assert {:ok, %{mode: :running}} = RuntimeControl.complete_resume(resumed_version, quota)
  end

  test "Implement and Deliver use separate sessions in the same workspace" do
    {test_root, trace_file, codex_binary} = fake_codex_fixture!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "Progress", "In Review"],
      tracker_review_state: "In Review",
      workspace_root: Path.join(test_root, "workspaces"),
      hook_after_create: "printf preserved > output.txt",
      codex_command: "#{codex_binary} app-server",
      max_turns: 3,
      prompt: "{% if issue.state == 'In Review' %}Deliver{% else %}Implement{% endif %} {{ issue.identifier }}"
    )

    issue = %Issue{id: "review-session", identifier: "SIGN-90001", state: "Ready", dispatchable: true}

    fetcher = fn [_] ->
      next_state = if Process.get(:review_task_progress_seen, false), do: "In Review", else: "Progress"
      Process.put(:review_task_progress_seen, true)
      {:ok, [%{issue | state: next_state}]}
    end

    assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: fetcher)
    output = Path.join([test_root, "workspaces", "SIGN-90001", "output.txt"])
    File.write!(output, "implementation output")
    assert :ok = AgentRunner.run(%{issue | state: "In Review"}, nil, issue_state_fetcher: fn [_] -> {:ok, [%{issue | state: "Progress"}]} end)
    assert :ok = AgentRunner.run(%{issue | state: "Progress"}, nil, issue_state_fetcher: fn [_] -> {:ok, [%{issue | state: "Done"}]} end)

    messages = trace_messages(trace_file)
    assert Enum.count(messages, &(&1["method"] == "thread/start")) == 3

    prompts = turn_prompts(messages)
    assert [implement, continuation, deliver, fix] = prompts
    assert implement == "Implement SIGN-90001"
    assert continuation =~ "Continuation guidance:"
    assert deliver == "Deliver SIGN-90001"
    assert fix == "Implement SIGN-90001"
    assert File.read!(output) == "implementation output"
  end

  test "survey handoff and resumed fixes get fresh prompts without losing workspace output" do
    {test_root, trace_file, codex_binary} = fake_codex_fixture!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "Progress", "In Review"],
      tracker_review_state: "In Review",
      tracker_session_boundary_states: ["Ready"],
      workspace_root: Path.join(test_root, "workspaces"),
      hook_after_create: "printf preserved > output.txt",
      codex_command: "#{codex_binary} app-server",
      max_turns: 3,
      prompt: "{% if issue.state == 'Ready' %}Survey{% elsif issue.state == 'Progress' %}Implement{% else %}Review{% endif %} {{ issue.identifier }}"
    )

    issue = %Issue{id: "survey-session", identifier: "SIGN-90002", state: "Ready", dispatchable: true}
    output = Path.join([test_root, "workspaces", issue.identifier, "output.txt"])

    for {before, after_state} <- [{"Ready", "Progress"}, {"Progress", "In Review"}, {"In Review", "Progress"}, {"Progress", "Done"}] do
      assert :ok = AgentRunner.run(%{issue | state: before}, nil, issue_state_fetcher: fn [_] -> {:ok, [%{issue | state: after_state}]} end)
      assert File.read!(output) == "preserved"
    end

    messages = trace_messages(trace_file)
    assert Enum.count(messages, &(&1["method"] == "thread/start")) == 4
    assert turn_prompts(messages) == ["Survey SIGN-90002", "Implement SIGN-90002", "Review SIGN-90002", "Implement SIGN-90002"]
  end

  defp fake_codex_fixture! do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf!(test_root) end)
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = Path.join(test_root, "fake-codex")

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file='#{trace_file}'
    if [ -f '#{test_root}/detached-child' ]; then
      setsid sleep 300 &
      printf '%s' "$!" > '#{test_root}/child.pid'
    fi
    printf 'RUN:%s\\n' "$$" >> "$trace_file"
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '{"id":2,"result":{"thread":{"id":"thread-%s"}}}\\n' "$$" ;;
        *'"method":"turn/start"'*)
          if [ -f '#{test_root}/hold-turn' ]; then
            sleep 300 &
            printf '%s' "$!" > '#{test_root}/child.pid'
          fi
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn"}}}'
          if [ ! -f '#{test_root}/hold-turn' ]; then
            printf '%s\\n' '{"method":"turn/completed"}'
          fi ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
    {test_root, trace_file, codex_binary}
  end

  defp trace_messages(trace_file) do
    lines = trace_file |> File.read!() |> String.split("\n", trim: true)

    messages =
      lines
      |> Enum.filter(&String.starts_with?(&1, "JSON:"))
      |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))

    assert Enum.count(lines, &String.starts_with?(&1, "RUN:")) == Enum.count(messages, &(&1["method"] == "thread/start"))
    messages
  end

  defp turn_prompts(messages) do
    messages
    |> Enum.filter(&(&1["method"] == "turn/start"))
    |> Enum.map(&get_in(&1, ["params", "input", Access.at(0), "text"]))
  end
end
