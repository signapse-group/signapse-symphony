defmodule SymphonyElixir.GroupedRuntimeTest do
  use ExUnit.Case, async: false

  import SymphonyElixir.TestSupport, only: [instructions_probe_root: 1, mount_instruction_fixture: 2]

  alias SymphonyElixir.{AssignmentOwners, HttpServer, Instructions, Orchestrator, Profile, RuntimeControl}
  alias SymphonyElixirWeb.Endpoint

  @ids ~w(fe be qa landing planning)
  @caps [2, 1, 2, 1, 1]

  defmodule JiraFixture do
    alias SymphonyElixir.Tracker.Issue

    def fetch_issues_by_states(_states, tracker) do
      candidates = issues(tracker)

      if File.exists?(tracker.env["PROBE_LIMIT_CANDIDATES"]) do
        {:ok, Enum.take(candidates, if(tracker.env["PROBE_PROFILE"] == "fe", do: 1, else: 0))}
      else
        {:ok, candidates}
      end
    end

    def fetch_issues_by_ids(ids, tracker), do: {:ok, Enum.filter(issues(tracker), &(&1.id in ids))}

    defp issues(tracker) do
      index = Enum.find_index(~w(fe be qa landing planning), &(&1 == tracker.env["PROBE_PROFILE"]))
      labels = tracker.required_labels ++ if(index == 2, do: ["qa-execute"], else: [])

      for slot <- 1..4 do
        id = Integer.to_string(10_000 + 10 * index + if(slot == 4, do: 0, else: slot))
        state = if index == 4 and slot == 4, do: "Ready", else: hd(tracker.dispatch_states)

        %Issue{
          id: id,
          identifier: "SIGN-" <> id,
          title: "Isolated probe",
          state: state,
          labels: if(slot == 4 and index < 4, do: ["wrong-route"], else: labels),
          dispatchable: true,
          admission_ready: true
        }
      end
    end
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "five contained workers load local instructions and wait at their own caps", %{tmp_dir: root} do
    if systemd_user?() do
      run_probe(instructions_probe_root(root))
    end
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "shared quota fences new work and continuations while retaining the running turn", %{tmp_dir: root} do
    if systemd_user?(), do: run_shared_quota_probe(instructions_probe_root(root))
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "repair and Resume reuse the checkout and open a task with its instructions", %{tmp_dir: root} do
    if systemd_user?(), do: run_checkout_resume_probe(root)
  end

  defp run_checkout_resume_probe(root) do
    put_test_config(:jira_client_module, JiraFixture)
    repo = Path.join(root, "checkout-source")
    provision_checkout_repo(repo)

    be = profile(root, "be", write_probe_script(root, "fake-codex-checkout"), 1, repo)
    start_supervised!({Profile, {[be], Path.join(root, "owners.sqlite3")}})
    assert eventually(fn -> snapshot("be").readiness.ready end)
    resume("be")

    assert eventually(fn ->
             match?(%{runtime_control: %{mode: :paused, source: "checkout_instructions"}, running: []}, snapshot("be"))
           end)

    assert %{retrying: [%{workspace_path: workspace, checkout_failure_path: "WORKFLOW.md"}]} = snapshot("be")
    refute File.exists?(trace_path(root, "be"))
    assert File.read!(Path.join(workspace, "hook-source")) == "checkout\n"

    local_output = Path.join(workspace, "local-output")
    File.write!(local_output, "preserve me")
    workflow = "CHECKOUT-ONLY {{ issue.identifier }} from [local AGENTS](AGENTS.md)."
    File.write!(Path.join(workspace, "WORKFLOW.md"), workflow)
    digest = Base.encode16(:crypto.hash(:sha256, workflow), case: :lower)

    resume("be")
    assert eventually(fn -> checkout_turn_started?(root) end), inspect(snapshot("be"))
    trace = File.read!(trace_path(root, "be"))
    assert trace =~ "THREAD-CWD:#{workspace}"
    assert trace =~ "CHECKOUT-ONLY SIGN-10011"
    assert trace =~ "relative to WORKFLOW.md in this checkout"
    refute trace =~ "uses instructions revision"

    {head, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
    head = String.trim(head)

    assert %{running: [%{checkout_head: ^head, checkout_prompt_digest: ^digest, workspace_path: ^workspace}]} =
             snapshot("be")

    assert File.read!(local_output) == "preserve me"
  end

  defp checkout_turn_started?(root) do
    case File.read(trace_path(root, "be")) do
      {:ok, trace} -> String.contains?(trace, "CHECKOUT-ONLY SIGN-10011")
      _ -> false
    end
  end

  defp provision_checkout_repo(repo) do
    {_, 0} = System.cmd("git", ["init", "--quiet", repo])
    File.write!(Path.join(repo, "AGENTS.md"), "# Checkout instructions\n")
    skill = Path.join([repo, ".agents", "skills", "example", "SKILL.md"])
    File.mkdir_p!(Path.dirname(skill))
    File.write!(skill, "# Example skill\n")
    git = ["-C", repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
    {_, 0} = System.cmd("git", git ++ ["add", "."])
    {_, 0} = System.cmd("git", git ++ ["commit", "--quiet", "-m", "Prepare checkout"])
  end

  defp run_shared_quota_probe(root) do
    put_test_config(:jira_client_module, JiraFixture)
    limit_candidates = Path.join(root, "limit-candidates")
    exhausted = Path.join(root, "quota-exhausted")
    complete_fe = Path.join(root, "complete-fe-turn")
    File.touch!(limit_candidates)

    fe = profile(root, "fe", write_probe_script(root, "fake-codex-fe"), 2)
    fe = put_in(fe.env["PROBE_COMPLETE_TURN"], complete_fe)
    be = profile(root, "be", write_probe_script(root, "fake-codex-be"))
    start_supervised!({Profile, {[fe, be], Path.join(root, "owners.sqlite3")}})
    assert eventually(fn -> Enum.all?(~w(fe be), &snapshot(&1).readiness.ready) end)
    resume("fe")
    resume("be")

    assert eventually(fn ->
             match?(%{running: [%{session_id: session_id}]} when is_binary(session_id), snapshot("fe")) and
               turn_started?(root, "fe")
           end)

    assert eventually(fn -> match?(%{runtime_control: %{mode: :running}}, snapshot("be")) end)
    [first] = snapshot("fe").running
    assert is_binary(first.codex_app_server_pid)
    first_trace = File.read!(trace_path(root, "fe"))
    assert quota_checks(root, "fe", "dispatch", 7) == 2

    File.touch!(exhausted)
    File.rm!(limit_candidates)

    assert eventually(fn ->
             Enum.all?(~w(fe be), fn id ->
               state = snapshot(id)
               state.admission_error == :provider_quota_exhausted and state.waiting != []
             end)
           end)

    assert quota_checks(root, "fe", "dispatch", 100) >= 1
    assert quota_checks(root, "be", "dispatch", 100) >= 1
    assert %{running: [still_running], readiness: %{ready: true}, runtime_control: %{mode: :running}} = snapshot("fe")
    assert still_running.session_id == first.session_id
    assert still_running.codex_app_server_pid == first.codex_app_server_pid
    assert %{running: [], readiness: %{ready: true}, runtime_control: %{mode: :running}} = snapshot("be")
    assert File.read!(trace_path(root, "fe")) == first_trace
    refute File.exists?(trace_path(root, "be"))
    assert {:ok, nil} = AssignmentOwners.owner({"https://jira.example.invalid", "SIGN", "10002"})
    assert {:ok, nil} = AssignmentOwners.owner({"https://jira.example.invalid", "SIGN", "10011"})

    File.touch!(limit_candidates)
    File.touch!(complete_fe)

    assert eventually(fn -> quota_checks(root, "fe", "session", 100) == 1 and snapshot("fe").running == [] end)
    assert File.read!(trace_path(root, "fe")) == first_trace
    fe_control = Profile.via("fe", :runtime_control)

    assert {:ok, [%{"attempt" => 1, "error" => "provider_quota_exhausted", "issue_id" => "10001"} = retry]} =
             RuntimeControl.pending_retries("fe", fe_control)

    refute retry["session_unit"]
    assert File.dir?(retry["workspace_path"])
    retry_checks = quota_checks(root, "fe", "dispatch", 100)
    assert eventually(fn -> quota_checks(root, "fe", "dispatch", 100) > retry_checks and snapshot("fe").retrying != [] end, 450)

    assert {:ok, [%{"attempt" => 1, "error" => "provider_quota_exhausted", "issue_id" => "10001"}]} =
             RuntimeControl.pending_retries("fe", fe_control)

    assert snapshot("fe").running == []
    File.rm!(exhausted)
    assert eventually(fn -> File.read!(trace_path(root, "fe")) != first_trace end, 450)
    assert snapshot("fe").admission_error == nil
  end

  defp run_probe(root) do
    put_test_config(:jira_client_module, JiraFixture)
    put_test_config(Endpoint, Application.fetch_env!(:symphony_elixir, Endpoint))
    script = write_probe_script(root)
    profiles = Enum.map(@ids, &profile(root, &1, script))
    start_supervised!({Profile, {profiles, Path.join(root, "owners.sqlite3")}})
    start_supervised!({HttpServer, mode: :profiles, port: 0})
    assert {:ok, {{127, 0, 0, 1}, port}} = Bandit.PhoenixAdapter.server_info(Endpoint, :http)
    assert eventually(fn -> state(port)["health"] == "healthy" end)

    qa_active = Path.join(instructions_path(root, "qa"), "active")
    File.rename!(qa_active, qa_active <> ".saved")
    assert eventually(fn -> state(port)["health"] == "partial" end)
    resume("fe")
    assert eventually(fn -> profile_counts(port, "fe", "running") == 2 and profile_counts(port, "fe", "waiting") > 0 end)
    assert profile_counts(port, "be", "running") == 0
    assert profile_counts(port, "qa", "running") == 0
    assert {:ok, _} = RuntimeControl.pause("QA probe pause while unready", "manual", Profile.via("qa", :runtime_control))
    File.rename!(qa_active <> ".saved", qa_active)
    assert eventually(fn -> state(port)["health"] == "healthy" end)
    assert profile_mode(port, "qa") == "paused"

    for id <- @ids -- ["fe"], do: resume(id)

    assert eventually(fn -> Enum.all?(@ids, &turn_started?(root, &1)) end), "Missing contained worker; #{retry_diagnostics()}"
    assert eventually(fn -> Enum.map(@ids, &profile_counts(port, &1, "running")) == @caps end)
    assert eventually(fn -> Enum.all?(@ids, &(profile_counts(port, &1, "waiting") > 0)) end)

    for id <- @ids do
      trace = File.read!(trace_path(root, id))
      package = package_path(root, id)
      revision = Path.basename(package)
      file_count = package |> Path.join("**/*") |> Path.wildcard(match_dot: true) |> Enum.count(&File.regular?/1)
      assert trace =~ "READ:#{revision}:readonly:#{file_count}"
      assert trace =~ "ENV:#{id}:unset"
      assert trace =~ "uses instructions revision #{revision}"
    end

    for index <- 0..4 do
      key = {"https://jira.example.invalid", "SIGN", Integer.to_string(10_000 + 10 * index)}
      assert {:ok, nil} = AssignmentOwners.owner(key)
    end

    verify_activation_and_restart(root, port)

    assert {:ok, _} = RuntimeControl.pause("FE probe drain", "manual", Profile.via("fe", :runtime_control))
    assert profile_mode(port, "fe") in ["paused", "pausing"]
    assert profile_mode(port, "be") == "running"
    assert Orchestrator.snapshot(Profile.via("be", :orchestrator), 5_000).max_concurrent_agents == 1
  end

  defp resume(id) do
    assert {:ok, %{mode: :checking_quota}} = RuntimeControl.resume(Profile.via(id, :runtime_control))
  end

  defp verify_activation_and_restart(root, port) do
    fe = Profile.via("fe", :orchestrator)
    old = package_path(root, "fe")
    old_revision = Path.basename(old)
    instructions = instructions_path(root, "fe")
    stage_package(root, "fe", "probe-v2")
    File.mkdir_p!(Path.join([instructions, "revisions", "invalid"]))
    assert {:error, _} = Instructions.activate("fe", "invalid")
    assert {:ok, %{revision: ^old_revision}} = Instructions.status("fe")
    assert {:ok, %{revision: "probe-v2"}} = Instructions.activate("fe", "probe-v2")
    assert profile_counts(port, "fe", "running") == 2
    refute File.read!(trace_path(root, "fe")) =~ "READ:probe-v2"

    workspace = Path.join([root, "workspaces", "fe"])
    output = Path.join([workspace, "SIGN-10001", "local-output"])
    File.write!(output, "retain me")
    fe_pid = GenServer.whereis(fe)
    be_pid = GenServer.whereis(Profile.via("be", :orchestrator))
    Process.exit(fe_pid, :kill)
    assert eventually(fn -> GenServer.whereis(fe) not in [nil, fe_pid] end)
    assert eventually(fn -> File.read!(trace_path(root, "fe")) =~ "READ:probe-v2" end), retry_diagnostics()
    assert eventually(fn -> profile_counts(port, "fe", "running") == 2 end)
    assert GenServer.whereis(Profile.via("be", :orchestrator)) == be_pid
    assert File.read!(output) == "retain me"
    assert {:ok, {"fe", ^workspace}} = AssignmentOwners.owner({"https://jira.example.invalid", "SIGN", "10001"})
  end

  defp profile(root, id, script, max_turns \\ 1, checkout_repo \\ nil) do
    control = Path.join(root, id <> ".sqlite3")
    workspace = Path.join([root, "workspaces", id])
    workflow = Path.join(root, id <> ".md")
    instructions = instructions_path(root, id)
    fixture = Path.expand("../fixtures/profiles/#{id}.md", __DIR__)
    contents = File.read!(fixture)
    contents = String.replace(contents, "max_concurrent_agents:", "max_turns: #{max_turns}\n  max_concurrent_agents:")
    contents = String.replace(contents, "\nworkspace:", "\npolling:\n  interval_ms: 100\nworkspace:")

    hook_config = if checkout_repo, do: checkout_fixture_hooks(), else: package_fixture_hooks()

    fixture_settings = """
    codex:
      command: #{script}
      read_timeout_ms: 15000
    #{String.trim_trailing(hook_config)}
    ---
    #{id} fixture
    """

    File.write!(workflow, String.replace(contents, "---\n#{id} fixture", String.trim_trailing(fixture_settings)))

    unless checkout_repo, do: prepare_package_fixture(root, id, instructions)

    %Profile{
      id: id,
      workflow_path: workflow,
      instructions_root: if(checkout_repo, do: nil, else: instructions),
      checkout_workflow: if(checkout_repo, do: "WORKFLOW.md"),
      control_path: control,
      env:
        %{
          "PATH" => System.fetch_env!("PATH"),
          "HOME" => System.fetch_env!("HOME"),
          "XDG_RUNTIME_DIR" => System.fetch_env!("XDG_RUNTIME_DIR"),
          "DBUS_SESSION_BUS_ADDRESS" => System.fetch_env!("DBUS_SESSION_BUS_ADDRESS"),
          "JIRA_BASE_URL" => "https://jira.example.invalid",
          "JIRA_EMAIL" => "probe@example.invalid",
          "JIRA_API_TOKEN" => "should-not-reach-worker",
          "SYMPHONY_WORKSPACE_ROOT" => workspace,
          "CONTROL_DB" => control,
          "PROBE_PROFILE" => id,
          "PROBE_TRACE" => trace_path(root, id),
          "PROBE_LIMIT_CANDIDATES" => Path.join(root, "limit-candidates"),
          "PROBE_QUOTA_EXHAUSTED" => Path.join(root, "quota-exhausted"),
          "PROBE_QUOTA_TRACE" => quota_trace_path(root, id)
        }
        |> Map.merge(if(checkout_repo, do: %{"PROBE_CHECKOUT_REPO" => checkout_repo}, else: %{}))
    }
  end

  defp package_fixture_hooks do
    ~S"""
    hooks:
      before_run: |
        test -r "$SYMPHONY_INSTRUCTIONS_ROOT/AGENTS.md" &&
        test "$PROBE_PROFILE" = "$SYMPHONY_PROFILE_ID" &&
        test -z "${JIRA_API_TOKEN+x}" &&
        printf '%s\n' "$SYMPHONY_INSTRUCTIONS_REVISION" > hook-revision
    """
  end

  defp checkout_fixture_hooks do
    ~S"""
    hooks:
      after_create: git clone --quiet "$PROBE_CHECKOUT_REPO" .
      before_run: |
        test "$SYMPHONY_INSTRUCTIONS_SOURCE" = checkout &&
        test -z "${SYMPHONY_INSTRUCTIONS_ROOT+x}${SYMPHONY_INSTRUCTIONS_REVISION+x}${JIRA_API_TOKEN+x}" &&
        printf '%s\n' "$SYMPHONY_INSTRUCTIONS_SOURCE" > hook-source
    """
  end

  defp prepare_package_fixture(root, id, instructions) do
    case System.get_env("SYMPHONY_TEST_PINNED_PACKAGES") do
      nil ->
        stage_package(root, id, "pinned-probe-v1")
        File.write!(Path.join(instructions, "active"), "pinned-probe-v1\n")

      dir ->
        File.mkdir_p!(Path.dirname(instructions))
        File.cp_r!(Path.join(dir, id), instructions)
        mount_instruction_fixture(root, package_path(root, id))
    end
  end

  defp stage_package(root, id, revision) do
    dir = Path.join([instructions_path(root, id), "revisions", revision])
    File.mkdir_p!(dir)
    manifest = Jason.encode!(%{profile_id: id, revision: revision, workflow: "WORKFLOW.md", required_files: []})

    for {name, body} <- [
          {"instructions.json", manifest},
          {"AGENTS.md", "This is a fixture."},
          {"WORKFLOW.md", "LOCAL-#{id} {{ issue.identifier }} from [local AGENTS](AGENTS.md)."}
        ] do
      file = Path.join(dir, name)
      File.write!(file, body)
      File.chmod!(file, 0o444)
    end

    mount_instruction_fixture(root, dir)
  end

  defp write_probe_script(root, name \\ "fake-codex") do
    path = Path.join(root, name)

    File.write!(path, """
    #!/usr/bin/env python3
    import json
    import os
    from pathlib import Path
    import re
    import sys
    import time

    thread_started = False
    for line in sys.stdin:
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            result = {}
        elif method == "account/rateLimits/read":
            usage = 100 if Path(os.environ["PROBE_QUOTA_EXHAUSTED"]).exists() else 7
            scope = "session" if thread_started else "dispatch"
            with open(os.environ["PROBE_QUOTA_TRACE"], "a") as trace:
                trace.write(f"{scope}:{usage}\\n")
            result = {"rateLimits": {"primary": {"usedPercent": usage}}}
        elif method == "thread/start":
            thread_started = True
            if os.environ.get("PROBE_CHECKOUT_REPO"):
                cwd = msg["params"]["cwd"]
                assert Path(cwd) == Path.cwd()
                assert Path("AGENTS.md").is_file()
                assert Path(".agents/skills/example/SKILL.md").is_file()
                assert Path("hook-source").read_text().strip() == "checkout"
                with open(os.environ["PROBE_TRACE"], "a") as trace:
                    trace.write(f"THREAD-CWD:{cwd}\\n")
            result = {"thread": {"id": f"thread-{os.getpid()}"}}
        elif method == "turn/start":
            prompt = msg["params"]["input"][0]["text"]
            with open(os.environ["PROBE_TRACE"], "a") as trace:
                if not os.environ.get("PROBE_CHECKOUT_REPO"):
                    root = Path(re.search(r"Read AGENTS.md and the required phase instructions from (.+)\\.\\n", prompt)[1])
                    assert os.statvfs(root).f_flag & os.ST_RDONLY
                    assert (root / "AGENTS.md").read_bytes()
                    assert Path("hook-revision").read_text().strip() == root.name
                    files = [path for path in root.rglob("*") if path.is_file()]
                    for path in files:
                        path.read_bytes()
                    trace.write(f"READ:{root.name}:readonly:{len(files)}\\n")
                trace.write(f"ENV:{os.environ['PROBE_PROFILE']}:{os.environ.get('JIRA_API_TOKEN', 'unset')}\\n")
                trace.write(prompt + "\\n")
            result = {"turn": {"id": "probe-turn"}}
        else:
            continue
        print(json.dumps({"id": msg["id"], "result": result}), flush=True)
        if method == "turn/start" and os.environ.get("PROBE_COMPLETE_TURN"):
            complete = Path(os.environ["PROBE_COMPLETE_TURN"])
            while not complete.exists():
                time.sleep(0.02)
            complete.unlink()
            print(json.dumps({"method": "turn/completed", "params": {"turn": {"status": "completed"}}}), flush=True)
        if method == "account/rateLimits/read" and not thread_started:
            break
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp turn_started?(root, id) do
    match?({:ok, contents} when byte_size(contents) > 0, File.read(trace_path(root, id)))
  end

  defp retry_diagnostics do
    for id <- @ids, into: %{} do
      {:ok, retries} = RuntimeControl.pending_retries(id, Profile.via(id, :runtime_control))
      {id, Enum.map(retries, &String.slice(&1["error"] || "", 0, 200))}
    end
    |> inspect()
  end

  defp trace_path(root, id), do: Path.join(root, id <> ".trace")
  defp quota_trace_path(root, id), do: Path.join(root, id <> ".quota")
  defp instructions_path(root, id), do: Path.join([root, "instructions", id])

  defp quota_checks(root, id, scope, usage) do
    {:ok, trace} = File.read(quota_trace_path(root, id))
    trace |> String.split("\n") |> Enum.count(&(&1 == "#{scope}:#{usage}"))
  end

  defp snapshot(id), do: Orchestrator.snapshot(Profile.via(id, :orchestrator), 5_000)

  defp package_path(root, id) do
    instructions = instructions_path(root, id)
    revision = instructions |> Path.join("active") |> File.read!() |> String.trim()
    Path.join([instructions, "revisions", revision])
  end

  defp state(port), do: get(port, "/api/v1/state")
  defp profile_counts(port, id, key), do: get_in(get(port, "/api/v1/profiles/#{id}/state"), ["counts", key]) || 0
  defp profile_mode(port, id), do: get_in(get(port, "/api/v1/profiles/#{id}/state"), ["runtime_control", "mode"])
  defp get(port, path), do: Req.get!("http://127.0.0.1:#{port}#{path}", retry: false).body

  defp systemd_user? do
    System.get_env("XDG_RUNTIME_DIR") != nil and System.get_env("DBUS_SESSION_BUS_ADDRESS") != nil
  end

  defp put_test_config(key, value) do
    previous = Application.get_env(:symphony_elixir, key)

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, key, previous)
      else
        Application.delete_env(:symphony_elixir, key)
      end
    end)

    Application.put_env(:symphony_elixir, key, value)
  end

  defp eventually(predicate, attempts \\ 300)
  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(100)
      eventually(predicate, attempts - 1)
    end
  end
end
