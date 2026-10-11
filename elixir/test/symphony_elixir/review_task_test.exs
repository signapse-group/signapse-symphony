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

  test "phase reconciliation retains the running worker claim until exit" do
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

    assert reconciled.running[issue.id].issue.state == "Progress"
    assert reconciled.running[issue.id].pid == worker
    assert MapSet.member?(reconciled.claimed, issue.id)
    assert Process.alive?(worker)
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
    printf 'RUN:%s\\n' "$$" >> "$trace_file"
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '{"id":2,"result":{"thread":{"id":"thread-%s"}}}\\n' "$$" ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn"}}}' '{"method":"turn/completed"}' ;;
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
