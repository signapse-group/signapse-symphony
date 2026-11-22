defmodule SymphonyElixir.ProfileSchedulerTest do
  use ExUnit.Case

  alias SymphonyElixir.{AgentRunner, AgentRuntimeSupervisor, AssignmentOwners, Workspace}
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Profile
  alias SymphonyElixir.RuntimeControl
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkflowStore

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
    def fetch_issues_by_states(_states, tracker), do: {:ok, checkout_issues(tracker)}

    def fetch_issues_by_ids(ids, tracker), do: {:ok, Enum.filter(checkout_issues(tracker), &(&1.id in ids))}

    defp checkout_issues(%{env: %{"CHECKOUT_PROBE" => "1"}}) do
      [%Issue{id: "101", identifier: "SIGN-101", title: "Checkout task", state: "Ready", labels: ["route-frontend"], dispatchable: true}]
    end

    defp checkout_issues(_tracker), do: []
  end

  test "profile quota subprocess uses its own credentials scope and environment", %{root: root} do
    profile = profile(root, "fe")
    script = Path.join(root, "fake-codex")
    trace = Path.join(root, "quota-trace")
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

    File.write!(script, """
    #!/bin/sh
    IFS= read -r line
    printf '%s\\n' '{"id":1,"result":{}}'
    """)

    assert {:error, :provider_quota_unavailable} = AppServer.check_admission_quota(snapshot)
  end

  test "a paused invalid profile recovers independently and keeps the latest pause", %{root: root} do
    profiles = for id <- ~w(fe be qa landing planning), do: profile(root, id)
    qa = Enum.find(profiles, &(&1.id == "qa"))
    qa_workflow = File.read!(qa.workflow_path)
    File.write!(qa.workflow_path, "---\ntracker: [\n---\n")

    start_supervised!({Profile, profiles})
    start_supervised!({AssignmentOwners, path: Path.join(root, "owners.db")})

    for profile <- profiles do
      start_supervised!({AgentRuntimeSupervisor, profile_id: profile.id})
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

    assert %{runtime_control: %{mode: :paused, reason: "Pause during bad workflow"}} = snapshot("qa")
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

  test "QA prerequisite hook reports typed checkout failures and clears inherited source paths", %{root: root} do
    qa = profile(root, "qa")

    workflow = File.read!(qa.workflow_path)

    hook_config = """
    hooks:
      before_run: |
        test "$SYMPHONY_INSTRUCTIONS_SOURCE" = checkout || exit 5
        test -z "${SYMPHONY_INSTRUCTIONS_ROOT+x}${SYMPHONY_INSTRUCTIONS_REVISION+x}" || exit 6
        exit "$(cat result)"
    ---
    qa fixture:
    """

    File.write!(qa.workflow_path, String.replace(workflow, "---\nqa fixture:", String.trim(hook_config)))
    qa = %{qa | env: Map.merge(qa.env, %{"PATH" => System.fetch_env!("PATH"), "SYMPHONY_INSTRUCTIONS_ROOT" => "/old", "SYMPHONY_INSTRUCTIONS_REVISION" => "old"})}
    start_supervised!({Profile, [qa]})
    assert {:ok, snapshot} = WorkflowStore.snapshot("qa")
    workspace = Path.join(snapshot.settings.workspace.root, "SIGN-12")
    File.mkdir_p!(workspace)
    result_file = Path.join(workspace, "result")
    issue = %Issue{identifier: "SIGN-12"}

    File.write!(result_file, "78")

    assert {:error, {:checkout_instructions, :checkout_instructions_invalid, "WORKFLOW.md"}} =
             Workspace.run_before_run_hook(workspace, issue, nil, snapshot)

    File.write!(result_file, "1")
    assert {:error, {:workspace_hook_failed, "before_run", 1, _}} = Workspace.run_before_run_hook(workspace, issue, nil, snapshot)
  end

  test "an unavailable upstream stops before a task session and survives scheduler restart", %{root: root} do
    fe = profile(root, "fe")
    workspace = Path.join(fe.env["SYMPHONY_WORKSPACE_ROOT"], "SIGN-101")
    File.mkdir_p!(workspace)
    marker = Path.join(workspace, "preserve-me")
    File.write!(marker, "existing output")
    trace = Path.join(root, "codex-trace")
    command = Path.join(root, "fake-codex")

    File.write!(command, ~S"""
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
        *'"method":"account/rateLimits/read"'*) printf '%s\n' '{"id":4,"result":{"rateLimits":{"primary":{"usedPercent":7}}}}'; printf 'quota\n' >> "$CHECKOUT_PROBE_TRACE"; exit 0 ;;
        *'"method":"thread/start"'*) printf 'thread\n' >> "$CHECKOUT_PROBE_TRACE"; exit 1 ;;
      esac
    done
    """)

    File.chmod!(command, 0o755)
    content = File.read!(fe.workflow_path)
    updated = String.replace(content, "---\nfe fixture:", "polling:\n  interval_ms: 50\ncodex:\n  command: #{command}\n---\nfe fixture:")
    File.write!(fe.workflow_path, updated)

    fe = %{
      fe
      | checkout_upstream: %{repository: "file://#{Path.join(root, "missing-upstream")}", branch: "main"},
        env: Map.merge(fe.env, %{"PATH" => System.fetch_env!("PATH"), "CHECKOUT_PROBE" => "1", "CHECKOUT_PROBE_TRACE" => trace})
    }

    start_supervised!({Profile, {[fe], Path.join(root, "owners.db")}})
    control = Profile.via("fe", :runtime_control)
    scheduler = Profile.via("fe", :orchestrator)
    assert_eventually(fn -> match?(%{readiness: %{ready: true}}, snapshot("fe")) end)
    assert {:ok, %{mode: :checking_quota}} = RuntimeControl.resume(control)

    assert_eventually(fn ->
      match?(%{runtime_control: %{mode: :paused, source: "checkout_instructions"}, running: []}, snapshot("fe"))
    end)

    assert {:ok, [%{"reason_code" => "checkout_upstream_unavailable", "checkout_failure_path" => "WORKFLOW.md", "workspace_path" => ^workspace}]} =
             RuntimeControl.pending_retries("fe", control)

    assert File.read!(marker) == "existing output"
    assert File.read!(trace) =~ "quota"
    refute File.read!(trace) =~ "thread"

    old = GenServer.whereis(scheduler)
    Process.exit(old, :kill)

    assert_eventually(fn ->
      GenServer.whereis(scheduler) not in [old, nil] and
        match?(%{runtime_control: %{mode: :paused, source: "checkout_instructions"}, retrying: [%{checkout_failure_path: "WORKFLOW.md"}]}, snapshot("fe"))
    end)
  end

  defp profile(root, id) do
    fixture = Path.join([__DIR__, "../fixtures/profiles", id <> ".md"])
    workflow_path = Path.join(root, id <> ".md")
    File.cp!(fixture, workflow_path)
    control_path = Path.join([root, "state", id <> ".db"])

    %Profile{
      id: id,
      workflow_path: workflow_path,
      checkout_workflow: "WORKFLOW.md",
      checkout_upstream: %{repository: "https://github.com/example/fixtures", branch: "main"},
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
