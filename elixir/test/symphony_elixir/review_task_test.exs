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

  test "Implement and Deliver use separate sessions in the same workspace" do
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

    lines = trace_file |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(lines, &String.starts_with?(&1, "RUN:")) == 3

    messages =
      lines
      |> Enum.filter(&String.starts_with?(&1, "JSON:"))
      |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))

    assert Enum.count(messages, &(&1["method"] == "thread/start")) == 3

    prompts =
      messages
      |> Enum.filter(&(&1["method"] == "turn/start"))
      |> Enum.map(&get_in(&1, ["params", "input", Access.at(0), "text"]))

    assert [implement, continuation, deliver, fix] = prompts
    assert implement == "Implement SIGN-90001"
    assert continuation =~ "Continuation guidance:"
    assert deliver == "Deliver SIGN-90001"
    assert fix == "Implement SIGN-90001"
    assert File.read!(output) == "implementation output"
  end
end
