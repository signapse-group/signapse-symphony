defmodule SymphonyElixir.ProfileSchedulerTest do
  use ExUnit.Case

  alias SymphonyElixir.{AgentRunner, AgentRuntimeSupervisor, AssignmentOwners}
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Instructions, as: LocalInstructions
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Profile
  alias SymphonyElixir.RuntimeControl
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkflowStore

  defmodule Instructions do
    def pin(id) do
      {:ok, %{revision: "fixture-#{id}", fingerprint: id}}
    end

    def status(id), do: {:ok, %{revision: "fixture-#{id}"}}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-profile-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    previous_client = Application.get_env(:symphony_elixir, :jira_client_module)
    Application.put_env(:symphony_elixir, :jira_client_module, __MODULE__.JiraClient)

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:symphony_elixir, :jira_client_module, previous_client),
        else: Application.delete_env(:symphony_elixir, :jira_client_module)
    end)

    %{root: root}
  end

  defmodule JiraClient do
    def fetch_issues_by_states(_states, _tracker), do: {:ok, []}
  end

  test "profile quota subprocess uses its own credentials scope and environment", %{root: root} do
    profile = profile(root, "fe")
    script = Path.join(root, "fake-codex")
    trace = Path.join(root, "quota-trace")
    instructions = profile.instructions_root
    File.mkdir_p!(instructions)
    home = Path.join(root, "codex-home")

    File.write!(script, """
    #!/bin/sh
    printf '%s|%s|%s\n' "$CODEX_HOME" "${JIRA_API_TOKEN-unset}" "${SYMPHONY_OTHER_PROFILE-unset}" > '#{trace}'
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
        *'"id":4'*) printf '%s\n' '{"id":4,"result":{"rateLimits":{"primary":{"usedPercent":7}}}}'; exit 0 ;;
      esac
    done
    """)

    File.chmod!(script, 0o755)
    prior = System.get_env("SYMPHONY_OTHER_PROFILE")
    System.put_env("SYMPHONY_OTHER_PROFILE", "other-profile-value")

    on_exit(fn ->
      if prior,
        do: System.put_env("SYMPHONY_OTHER_PROFILE", prior),
        else: System.delete_env("SYMPHONY_OTHER_PROFILE")
    end)

    content = File.read!(profile.workflow_path)
    content = String.replace(content, "---\nfe fixture:", "codex:\n  command: #{script}\n---\nfe fixture:")
    File.write!(profile.workflow_path, content)
    profile = %{profile | env: Map.merge(profile.env, %{"PATH" => System.get_env("PATH"), "CODEX_HOME" => home})}
    start_supervised!({Profile, [profile]})
    assert {:ok, snapshot} = WorkflowStore.snapshot("fe")
    assert {:ok, %{available?: true}} = AppServer.read_rate_limits(snapshot)
    assert String.trim(File.read!(trace)) == "#{home}|unset|unset"
  end

  test "a paused invalid profile recovers independently and keeps the latest pause", %{root: root} do
    profiles = for id <- ~w(fe be qa landing planning), do: profile(root, id)
    qa = Enum.find(profiles, &(&1.id == "qa"))
    qa_workflow = File.read!(qa.workflow_path)
    File.write!(qa.workflow_path, "---\ntracker: [\n---\n")

    start_supervised!({Profile, profiles})
    start_supervised!({AssignmentOwners, path: Path.join(root, "owners.db")})

    for profile <- profiles do
      start_supervised!({AgentRuntimeSupervisor, profile_id: profile.id, instructions: Instructions})
    end

    assert_eventually(fn ->
      match?(%{readiness: %{ready: false}}, snapshot("qa")) and
        match?(%{readiness: %{ready: true}, max_concurrent_agents: 2}, snapshot("fe"))
    end)

    qa_control = Profile.via("qa", :runtime_control)
    assert {:ok, %{mode: :paused}} = RuntimeControl.pause("Pause during bad workflow", "manual", qa_control)
    File.write!(qa.workflow_path, qa_workflow)
    assert :ok = WorkflowStore.force_reload("qa")
    assert %{queued: true} = Orchestrator.request_refresh(Profile.via("qa", :orchestrator))

    for {id, cap} <- [{"fe", 2}, {"be", 1}, {"qa", 2}, {"landing", 1}, {"planning", 1}] do
      assert_eventually(fn ->
        match?(%{readiness: %{ready: true}, max_concurrent_agents: ^cap}, snapshot(id))
      end)
    end

    assert %{runtime_control: %{mode: :paused, reason: "Pause during bad workflow"}, instructions_revision: "fixture-qa"} = snapshot("qa")
    assert %{runtime_control: %{mode: :paused, source: "system"}} = snapshot("be")

    fe_orchestrator = GenServer.whereis(Profile.via("fe", :orchestrator))
    qa_orchestrator = GenServer.whereis(Profile.via("qa", :orchestrator))
    qa_supervisor = GenServer.whereis(Profile.via("qa", :task_supervisor))
    worker = start_supervised_worker(qa_supervisor)
    worker_ref = Process.monitor(worker)
    Process.exit(qa_orchestrator, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    assert_eventually(fn ->
      match?(%{readiness: %{ready: true}, runtime_control: %{reason: "Pause during bad workflow"}}, snapshot("qa"))
    end)

    assert GenServer.whereis(Profile.via("fe", :orchestrator)) == fe_orchestrator
    refute GenServer.whereis(Profile.via("qa", :orchestrator)) == qa_orchestrator
  end

  test "a Jira assignment owner is atomic across profiles and durable across store restarts", %{root: root} do
    path = Path.join(root, "owners.db")
    start_supervised!({AssignmentOwners, path: path})
    key = {"https://jira.example.invalid", "SIGN", "10001"}
    profiles = for id <- ~w(fe be), do: {id, Path.join(root, id)}

    results =
      profiles
      |> Task.async_stream(fn owner -> {owner, AssignmentOwners.claim(key, owner)} end)
      |> Enum.map(fn {:ok, result} -> result end)

    [{winner, :ok}] = Enum.filter(results, &match?({_, :ok}, &1))
    [{loser, {:error, :assignment_owned_by_other_profile}}] = Enum.reject(results, &match?({_, :ok}, &1))
    :ok = stop_supervised(AssignmentOwners)
    start_supervised!({AssignmentOwners, path: path})

    assert {:ok, ^winner} = AssignmentOwners.owner(key)
    assert :ok = AssignmentOwners.claim(key, winner)
    assert {:error, :assignment_owned_by_other_profile} = AssignmentOwners.claim(key, loser)
    assert {:error, :assignment_workspace_changed} = AssignmentOwners.claim(key, {elem(winner, 0), root})

    assert {:error, :assignment_authority_changed} =
             AssignmentOwners.claim({"https://another.example.invalid", "SIGN", "10001"}, winner)

    scope = %{base_url: elem(key, 0), project_key: elem(key, 1)}
    assert {:ok, foreign} = AssignmentOwners.foreign_assignments(scope, loser, ["10001", "10002"])
    assert MapSet.equal?(foreign, MapSet.new(["10001"]))
  end

  test "an idle scheduler detects sealed instruction drift without changing the active revision", %{root: root} do
    profile = profile(root, "fe")
    package = Path.join([profile.instructions_root, "revisions", "v1"])
    File.mkdir_p!(package)
    manifest = %{profile_id: "fe", revision: "v1", workflow: "WORKFLOW.md", required_files: []}
    write_sealed(Path.join(package, "instructions.json"), Jason.encode!(manifest))
    write_sealed(Path.join(package, "WORKFLOW.md"), "Use [instructions](AGENTS.md).")
    guidance = Path.join(package, "AGENTS.md")
    write_sealed(guidance, "Original guidance")

    start_supervised!({Profile, [profile]})
    start_supervised!({AssignmentOwners, path: Path.join(root, "owners.db")})
    assert {:ok, original_pin} = LocalInstructions.activate("fe", "v1")
    start_supervised!({AgentRuntimeSupervisor, profile_id: "fe"})
    assert_eventually(fn -> match?(%{readiness: %{ready: true}}, snapshot("fe")) end)

    write_sealed(guidance, "Changed guidance")
    assert {:ok, %{revision: "v1"}} = LocalInstructions.status("fe")
    assert {:ok, changed_pin} = LocalInstructions.pin("fe")
    refute original_pin.fingerprint == changed_pin.fingerprint

    scheduler = Profile.via("fe", :orchestrator)
    expired = System.monotonic_time(:millisecond) - 1
    :sys.replace_state(scheduler, fn state -> %{state | instructions_check_at: expired} end)
    assert %{queued: true} = Orchestrator.request_refresh(scheduler)

    assert_eventually(fn ->
      match?(%{readiness: %{ready: false, error: :active_instructions_changed}}, snapshot("fe"))
    end)

    assert %{instructions_revision: "v1"} = snapshot("fe")

    write_sealed(guidance, "Original guidance")
    assert %{queued: true} = Orchestrator.request_refresh(scheduler)
    assert_eventually(fn -> match?(%{readiness: %{ready: true}, instructions_revision: "v1"}, snapshot("fe")) end)
  end

  test "QA admission requires exactly one operation and an operation change ends its phase", %{root: root} do
    profile = profile(root, "qa")
    start_supervised!({Profile, [profile]})
    assert {:ok, snapshot} = WorkflowStore.snapshot("qa")
    state = %Orchestrator.State{profile_id: "qa", profile_snapshot: snapshot, max_concurrent_agents: 2}
    candidate = %Issue{id: "10001", identifier: "SIGN-1", title: "QA", state: "Ready", dispatchable: true, admission_ready: true}

    for labels <- [[], ["qa-generate", "qa-execute"]] do
      refute Orchestrator.should_dispatch_issue_for_test(%{candidate | labels: ["route-quality-assurance" | labels]}, state)
    end

    generate = %{candidate | labels: ["route-quality-assurance", "qa-generate"]}
    execute = %{candidate | labels: ["route-quality-assurance", "qa-execute"]}
    assert Orchestrator.should_dispatch_issue_for_test(generate, state)
    refute AgentRunner.same_agent_task?(generate, execute, snapshot.settings.tracker, "qa")
  end

  defp profile(root, id) do
    fixture = Path.join([__DIR__, "../fixtures/profiles", id <> ".md"])
    workflow_path = Path.join(root, id <> ".md")
    File.cp!(fixture, workflow_path)
    control_path = Path.join([root, "state", id <> ".db"])

    %Profile{
      id: id,
      workflow_path: workflow_path,
      instructions_root: Path.join([root, "instructions", id]),
      control_path: control_path,
      env: %{
        "JIRA_BASE_URL" => "https://jira.example.invalid",
        "JIRA_EMAIL" => id <> "@example.invalid",
        "JIRA_API_TOKEN" => id <> "-test-token",
        "SYMPHONY_WORKSPACE_ROOT" => Path.join([root, "workspaces", id]),
        "CONTROL_DB" => control_path
      }
    }
  end

  defp snapshot(id), do: Orchestrator.snapshot(Profile.via(id, :orchestrator), 1_000)

  defp write_sealed(path, content) do
    if File.exists?(path), do: File.chmod!(path, 0o644)
    File.write!(path, content)
    File.chmod!(path, 0o444)
  end

  defp start_supervised_worker(task_supervisor) do
    {:ok, pid} = Task.Supervisor.start_child(task_supervisor, fn -> Process.sleep(:infinity) end)
    pid
  end

  defp assert_eventually(predicate, attempts \\ 100)
  defp assert_eventually(predicate, 0), do: assert(predicate.())

  defp assert_eventually(predicate, attempts) do
    if not predicate.() do
      Process.sleep(20)
      assert_eventually(predicate, attempts - 1)
    end
  end
end
