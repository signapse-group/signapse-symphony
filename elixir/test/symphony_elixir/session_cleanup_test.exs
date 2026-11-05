defmodule SymphonyElixir.SessionCleanupTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RuntimeControl

  test "an unconfirmed stop retains the primary error and logs it before cleanup" do
    owner = self()
    on_stopped = fn -> send(owner, :stopped) end

    log =
      capture_log(fn ->
        assert {:session_stop_unconfirmed, failure} =
                 catch_exit(AppServer.with_session(%{}, fn -> {:error, :runtime_paused} end, on_stopped: on_stopped))

        assert failure.primary_error == %{kind: :error, reason: :runtime_paused, stacktrace: []}
        assert failure.stop_error == %{kind: :error, reason: :session_process_unknown, stacktrace: []}
        refute_receive :stopped
      end)

    assert log =~ "before session cleanup"
    assert log =~ "runtime_paused"
  end

  test "an unconfirmed stop retains an exception's original stack" do
    assert {:session_stop_unconfirmed, failure} =
             catch_exit(AppServer.with_session(%{}, &primary_exception!/0))

    assert %{kind: :error, reason: %RuntimeError{message: "primary exception"}, stacktrace: stacktrace} = failure.primary_error
    assert [{__MODULE__, :primary_exception!, 0, _} | _] = stacktrace
    assert failure.stop_error.reason == :session_process_unknown
  end

  test "successful output is omitted when cleanup fails" do
    assert {:session_stop_unconfirmed, failure} =
             catch_exit(AppServer.with_session(%{}, fn -> {:ok, "private successful output"} end))

    assert failure.primary_error == nil
    refute inspect(failure) =~ "private successful output"
  end

  test "malformed session metadata cannot prevent cleanup or replace the primary error" do
    session = %{thread_id: %{bad: "private response"}}

    log =
      capture_log(fn ->
        result = catch_exit(AppServer.with_session(session, fn -> {:error, :primary_failure} end))
        assert {:session_stop_unconfirmed, failure} = result
        assert failure.primary_error.reason == :primary_failure
        assert failure.stop_error.reason == :session_process_unknown
      end)

    assert log =~ "thread_id=invalid"
    refute log =~ "private response"
  end

  test "confirmed cleanup preserves return values and calls the stopped callback once" do
    for result <- [:ok, {:ok, :delivered}, {:error, :runtime_paused}] do
      session = plain_session!()
      owner = self()

      assert AppServer.with_session(session, fn -> result end, on_stopped: fn -> send(owner, :stopped) end) == result
      assert Port.info(session.port) == nil
      assert_receive :stopped
      refute_receive :stopped
    end
  end

  test "confirmed cleanup re-raises the original exception, exit and throw" do
    session = plain_session!()

    try do
      AppServer.with_session(session, &primary_exception!/0)
      flunk("expected primary exception")
    rescue
      error in RuntimeError ->
        assert error.message == "primary exception"
        assert [{__MODULE__, :primary_exception!, 0, _} | _] = __STACKTRACE__
    end

    assert Port.info(session.port) == nil
    assert catch_exit(AppServer.with_session(plain_session!(), fn -> exit(:primary_exit) end)) == :primary_exit
    assert catch_throw(AppServer.with_session(plain_session!(), fn -> throw(:primary_throw) end)) == :primary_throw
  end

  test "a cleanup exception cannot replace a returned primary error" do
    session = plain_session!()
    on_stopped = fn -> raise "cleanup exception" end

    assert {:session_stop_unconfirmed, failure} =
             catch_exit(AppServer.with_session(session, fn -> {:error, :primary_failure} end, on_stopped: on_stopped))

    assert failure.primary_error.reason == :primary_failure
    assert %{kind: :error, reason: %RuntimeError{message: "cleanup exception"}, stacktrace: [_ | _]} = failure.stop_error
    assert Port.info(session.port) == nil
  end

  test "failed initialization retains both startup and containment errors" do
    workspace = failing_session_fixture!(:initialize)
    owner = self()

    {worker, ref} =
      spawn_monitor(fn ->
        AppServer.start_session(workspace, on_stopped: fn -> send(owner, :stopped) end)
      end)

    assert_receive {:DOWN, ^ref, :process, ^worker, {:session_stop_unconfirmed, failure}}, 5_000
    assert_fixture_request(workspace, "initialize")
    assert failure.primary_error.reason == {:response_error, %{"message" => "fixture initialization failed"}}
    assert failure.stop_error.reason != nil
    refute_receive :stopped
  end

  test "the direct app-server runner retains a turn startup error when containment fails" do
    workspace = failing_session_fixture!(:turn)
    issue = %Issue{id: "direct-cleanup", identifier: "SIGN-CLEANUP", title: "Cleanup", state: "Progress"}
    {worker, ref} = spawn_monitor(fn -> AppServer.run(workspace, "test", issue) end)

    assert_receive {:DOWN, ^ref, :process, ^worker, {:session_stop_unconfirmed, failure}}, 5_000
    assert_fixture_request(workspace, "turn/start")
    assert failure.primary_error.reason == {:response_error, %{"message" => "fixture turn failed"}}
    assert failure.stop_error.reason != nil
  end

  test "an isolated admission timeout before turn startup remains observable when containment fails" do
    workspace = failing_session_fixture!(:turn)
    issue = %Issue{id: "admission-cleanup", identifier: "SIGN-CLEANUP", title: "Cleanup", state: "Progress"}
    control_name = Module.concat(__MODULE__, "DelayedControl#{System.unique_integer([:positive])}")
    path = workspace |> Path.dirname() |> Path.dirname() |> Path.join("control.sqlite3")
    control = start_supervised!({RuntimeControl, name: control_name, path: path, runtime_id: "cleanup-timeout"})
    assert {:ok, %{resume_version: version}} = RuntimeControl.begin_resume(control)
    assert {:ok, %{mode: :running}} = RuntimeControl.complete_resume(version, {:ok, %{available?: true}}, control)
    :ok = :sys.suspend(control)
    {worker, ref} = spawn_monitor(fn -> AppServer.run(workspace, "test", issue, runtime_control: control_name) end)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    log =
      try do
        capture_log(fn ->
          assert_receive {:DOWN, ^ref, :process, ^worker, {:session_stop_unconfirmed, failure}}, 15_000
          assert_fixture_request(workspace, "thread/start")
          assert {:runtime_control_unavailable, {:timeout, _}} = failure.primary_error.reason
          assert failure.stop_error.reason != nil
        end)
      after
        :sys.resume(control)
      end

    assert log =~ "before session cleanup"
    assert log =~ "runtime_control_unavailable"
    refute log =~ "Codex session failed"
    requests = workspace |> Path.dirname() |> Path.dirname() |> Path.join("requests") |> File.read!()
    assert requests =~ "shell:-lc"
    assert requests =~ "shell:-c"
    assert requests =~ "thread/start"
    refute requests =~ "turn/start"
    send(control, :heartbeat)
    assert {:ok, %{active_turns: 0}} = RuntimeControl.status(control)
  end

  test "startup callback failure cannot replace the original initialization error" do
    workspace = failing_session_fixture!(:initialize, stop_result: :ok)

    {worker, ref} =
      spawn_monitor(fn ->
        AppServer.start_session(workspace, on_stopped: fn -> raise "startup metadata cleanup failed" end)
      end)

    assert_receive {:DOWN, ^ref, :process, ^worker, {:session_stop_unconfirmed, failure}}, 5_000
    assert_fixture_request(workspace, "initialize")
    assert failure.primary_error.reason == {:response_error, %{"message" => "fixture initialization failed"}}
    assert %{reason: %RuntimeError{message: "startup metadata cleanup failed"}} = failure.stop_error
  end

  test "agent cleanup preserves the exception, skips after-run and retains scheduler ownership" do
    workspace = failing_session_fixture!(:turn, prompt: "{{ missing.required }}", hook_after_run: "true")
    issue = %Issue{id: "agent-cleanup", identifier: "SIGN-CLEANUP", title: "Cleanup", state: "Progress"}
    owner = self()

    {worker, ref} =
      spawn_monitor(fn ->
        AgentRunner.run(issue, nil,
          on_after_run: fn ->
            send(owner, :after_run_called)
            exit(:would_replace_original_error)
          end
        )
      end)

    assert_receive {:DOWN, ^ref, :process, ^worker, {:session_stop_unconfirmed, failure} = reason}, 5_000
    assert_fixture_request(workspace, "thread/start")
    assert %{kind: :error, reason: %Solid.RenderError{}, stacktrace: [_ | _]} = failure.primary_error
    refute_receive :after_run_called

    entry = %{
      pid: worker,
      ref: ref,
      issue: issue,
      identifier: issue.identifier,
      started_at: DateTime.utc_now(),
      workspace_path: workspace
    }

    state = %Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), codex_totals: %{}}
    assert {:noreply, held} = Orchestrator.handle_info({:DOWN, ref, :process, worker, reason}, state)
    assert MapSet.member?(held.claimed, issue.id)
    assert held.retry_attempts == %{}
    assert held.running[issue.id].handoff_error =~ "primary_error"
    assert held.running[issue.id].handoff_error =~ "stop_error"
  end

  defp primary_exception!, do: raise("primary exception")

  defp assert_fixture_request(workspace, method) do
    path = workspace |> Path.dirname() |> Path.dirname() |> Path.join("requests")

    trace =
      case File.read(path) do
        {:ok, trace} -> trace
        {:error, reason} -> "unavailable: #{reason}"
      end

    assert trace =~ "systemd-run:started" and trace =~ method,
           "Fixture did not reach #{method}; requests=#{inspect(trace)}"
  end

  defp plain_session! do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    %{port: port, containment: nil}
  end

  defp failing_session_fixture!(failure, overrides \\ []) do
    {stop_result, overrides} = Keyword.pop(overrides, :stop_result, :error)
    root = Path.join(System.tmp_dir!(), "symphony-cleanup-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    workspace = Path.join([root, "workspaces", "SIGN-CLEANUP"])
    File.mkdir_p!(bin)
    File.mkdir_p!(workspace)
    previous_path = System.get_env("PATH")
    fixture_path = bin <> ":" <> previous_path
    requests = "'" <> String.replace(Path.join(root, "requests"), "'", "'\"'\"'") <> "'"
    System.put_env("PATH", fixture_path)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf!(root)
    end)

    # The stdio fixture must not depend on the host's login profile or BASH_ENV.
    File.write!(Path.join(bin, "bash"), """
    #!/bin/sh
    unset BASH_ENV
    printf '%s\\n' "shell:$1" >> #{requests}
    exec /bin/bash -c "$2"
    """)

    initialize = if failure == :initialize, do: ~s({"error":{"message":"fixture initialization failed"}}), else: ~s({"result":{}})
    initialize = String.replace_prefix(initialize, "{", ~s({"id":1,))

    stop = if stop_result == :ok, do: "printf '%s\\n' 'LoadState=not-found'", else: "exit 1"

    File.write!(Path.join(bin, "systemctl"), """
    #!/bin/sh
    case "$3" in
      symphony-session-*.service)
        printf '%s\\n' 'systemctl:session' >> #{requests}
        #{stop}
        ;;
      *)
        printf '%s\\n' 'systemctl:owner' >> #{requests}
        printf '%s\\n' 'LoadState=not-found'
        ;;
    esac
    """)

    File.write!(Path.join(bin, "systemd-run"), """
    #!/bin/sh
    printf '%s\\n' 'systemd-run:started' >> #{requests}
    printf '%s\\n' 'SYMPHONY_CGROUP:11111111111111111111111111111111'
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> #{requests}
      case "$line" in
        *'"id":1'*) printf '%s\\n' '#{initialize}' ;;
        *'"id":2'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"fixture-thread"}}}' ;;
        *'"id":3'*) printf '%s\\n' '{"id":3,"error":{"message":"fixture turn failed"}}' ;;
      esac
    done
    """)

    for executable <- ["bash", "systemctl", "systemd-run"], do: File.chmod!(Path.join(bin, executable), 0o755)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge([tracker_kind: "memory", tracker_session_boundary_states: ["Ready"], workspace_root: Path.join(root, "workspaces"), codex_command: "unused-fixture-command"], overrides)
    )

    workspace
  end
end
