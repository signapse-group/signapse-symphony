defmodule SymphonyElixir.GroupedRuntimeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AssignmentOwners, HttpServer, Instructions, Orchestrator, Profile, RuntimeControl}
  alias SymphonyElixirWeb.Endpoint

  @ids ~w(fe be qa landing planning)
  @caps [2, 1, 2, 1, 1]

  defmodule JiraFixture do
    alias SymphonyElixir.Tracker.Issue

    def fetch_issues_by_states(_states, tracker), do: {:ok, issues(tracker)}
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
      run_probe(root)
    end
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
    stage_package(instructions, "fe", "probe-v2")
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

  defp profile(root, id, script) do
    control = Path.join(root, id <> ".sqlite3")
    workspace = Path.join([root, "workspaces", id])
    workflow = Path.join(root, id <> ".md")
    instructions = instructions_path(root, id)
    fixture = Path.expand("../fixtures/profiles/#{id}.md", __DIR__)
    contents = File.read!(fixture)
    contents = String.replace(contents, "max_concurrent_agents:", "max_turns: 1\n  max_concurrent_agents:")
    contents = String.replace(contents, "\nworkspace:", "\npolling:\n  interval_ms: 100\nworkspace:")

    fixture_settings = """
    codex:
      command: #{script}
      read_timeout_ms: 15000
    hooks:
      before_run: |
        test -r "$SYMPHONY_INSTRUCTIONS_ROOT/AGENTS.md" &&
        test "$PROBE_PROFILE" = "$SYMPHONY_PROFILE_ID" &&
        test -z "${JIRA_API_TOKEN+x}" &&
        printf '%s\\n' "$SYMPHONY_INSTRUCTIONS_REVISION" > hook-revision
    ---
    #{id} fixture
    """

    File.write!(workflow, String.replace(contents, "---\n#{id} fixture", String.trim_trailing(fixture_settings)))

    case System.get_env("SYMPHONY_TEST_PINNED_PACKAGES") do
      nil ->
        stage_package(instructions, id, "pinned-probe-v1")
        File.write!(Path.join(instructions, "active"), "pinned-probe-v1\n")

      dir ->
        File.mkdir_p!(Path.dirname(instructions))
        File.cp_r!(Path.join(dir, id), instructions)
    end

    %Profile{
      id: id,
      workflow_path: workflow,
      instructions_root: instructions,
      control_path: control,
      env: %{
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
        "PROBE_TRACE" => trace_path(root, id)
      }
    }
  end

  defp stage_package(root, id, revision) do
    dir = Path.join([root, "revisions", revision])
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
  end

  defp write_probe_script(root) do
    path = Path.join(root, "fake-codex")

    File.write!(path, """
    #!/usr/bin/env python3
    import json
    import os
    from pathlib import Path
    import re
    import sys

    for line in sys.stdin:
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            result = {}
        elif method == "account/rateLimits/read":
            result = {"rateLimits": {"primary": {"usedPercent": 7}}}
        elif method == "thread/start":
            result = {"thread": {"id": f"thread-{os.getpid()}"}}
        elif method == "turn/start":
            prompt = msg["params"]["input"][0]["text"]
            root = Path(re.search(r"Read AGENTS.md and the required phase instructions from (.+)\\.\\n", prompt)[1])
            assert os.statvfs(root).f_flag & os.ST_RDONLY
            assert (root / "AGENTS.md").read_bytes()
            assert Path("hook-revision").read_text().strip() == root.name
            files = [path for path in root.rglob("*") if path.is_file()]
            for path in files:
                path.read_bytes()
            with open(os.environ["PROBE_TRACE"], "a") as trace:
                trace.write(f"READ:{root.name}:readonly:{len(files)}\\n")
                trace.write(f"ENV:{os.environ['PROBE_PROFILE']}:{os.environ.get('JIRA_API_TOKEN', 'unset')}\\n")
                trace.write(prompt + "\\n")
            result = {"turn": {"id": "probe-turn"}}
        else:
            continue
        print(json.dumps({"id": msg["id"], "result": result}), flush=True)
        if method == "account/rateLimits/read":
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
  defp instructions_path(root, id), do: Path.join([root, "instructions", id])

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
