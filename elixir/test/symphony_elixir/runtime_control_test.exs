defmodule SymphonyElixir.RuntimeControlTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias SymphonyElixir.RuntimeControl

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-control-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: Path.join(root, "control.sqlite3")}
  end

  test "fresh and recreated databases require manual quota-checked resume", %{path: path} do
    first = start_control(path, "be")
    assert {:ok, %{mode: :paused, source: "system"}} = RuntimeControl.status(first)
    assert {:error, :runtime_paused} = RuntimeControl.acquire_turn(first)
    resume(first)
    stop_control(first)
    File.rm!(path)
    second = start_control(path, "be")
    assert {:ok, %{mode: :paused}} = RuntimeControl.status(second)
  end

  test "three service controls share pause, drain, and restart state", %{path: path} do
    members = ["be", "fe", "landing"]
    first = start_control(path, "be", members: members)
    second = start_control(path, "fe", members: members)
    third = start_control(path, "landing", members: members)
    resume(first)
    assert {:ok, token} = RuntimeControl.acquire_turn(second)
    assert {:ok, %{mode: :pausing, active_turns: 1}} = RuntimeControl.pause("Quota exhausted", "quota", third)
    assert {:error, :runtime_paused} = RuntimeControl.acquire_turn(first)
    assert {:ok, %{mode: :pausing}} = RuntimeControl.status(first)
    assert {:ok, %{mode: :paused}} = RuntimeControl.release_turn(token, second)
    stop_control(first)
    restarted = start_control(path, "be", members: members)
    assert {:ok, %{mode: :paused, reason: "Quota exhausted", source: "quota"}} = RuntimeControl.status(restarted)
  end

  test "isolated FE control can pause without stopping BE or landing", %{path: path} do
    backend = start_control(path, "be", members: ["be", "landing"])
    landing = start_control(path, "landing", members: ["be", "landing"])
    frontend = start_control(path <> ".fe", "fe", members: ["fe"])
    resume(backend)
    resume(frontend)
    assert {:ok, %{mode: :paused}} = RuntimeControl.pause("Infrastructure retry limit", "infrastructure", frontend)
    assert {:ok, %{mode: :running}} = RuntimeControl.status(backend)
    assert {:ok, %{mode: :running}} = RuntimeControl.status(landing)
    assert {:ok, token} = RuntimeControl.acquire_turn(backend)
    assert {:ok, _} = RuntimeControl.release_turn(token, backend)
    stop_control(frontend)
    restarted = start_control(path <> ".fe", "fe", members: ["fe"])
    assert {:ok, %{mode: :paused, source: "infrastructure"}} = RuntimeControl.status(restarted)
  end

  test "control-only restart reconstructs live turn ownership", %{path: path} do
    first = start_control(path, "be")
    resume(first)
    assert {:ok, token} = RuntimeControl.acquire_turn(first)
    assert {:ok, %{mode: :pausing}} = RuntimeControl.pause("Manual pause", "manual", first)
    stop_control(first)
    restarted = start_control(path, "be")
    assert {:ok, %{mode: :pausing, active_turns: 1}} = RuntimeControl.status(restarted)
    assert {:error, :not_paused} = RuntimeControl.begin_resume(restarted)
    assert {:ok, %{mode: :paused, active_turns: 0}} = RuntimeControl.release_turn(token, restarted)
  end

  test "dead turn owner is reaped after control restart", %{path: path} do
    first = start_control(path, "be")
    resume(first)
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:permit, RuntimeControl.acquire_turn(first)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:permit, {:ok, _token}}
    RuntimeControl.pause("Manual pause", "manual", first)
    stop_control(first)
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    restarted = start_control(path, "be")
    assert {:ok, %{mode: :paused, active_turns: 0}} = RuntimeControl.status(restarted)
  end

  test "a newer pause supersedes quota check without clearing its reason", %{path: path} do
    first = start_control(path, "be")
    second = start_control(path, "fe")
    assert {:ok, %{resume_version: version}} = RuntimeControl.begin_resume(first)
    RuntimeControl.pause("Operator pause", "manual", second)
    assert {:error, :resume_superseded} = RuntimeControl.complete_resume(version, quota_available(), first)
    assert {:ok, %{mode: :paused, source: "manual", reason: "Operator pause"}} = RuntimeControl.status(first)
  end

  test "starting another service does not cancel an active quota check", %{path: path} do
    first = start_control(path, "be")
    assert {:ok, %{resume_version: version}} = RuntimeControl.begin_resume(first)
    second = start_control(path, "fe")
    assert {:ok, %{mode: :checking_quota}} = RuntimeControl.status(second)
    assert {:ok, %{mode: :running}} = RuntimeControl.complete_resume(version, quota_available(), first)
  end

  test "missing or invalid quota results remain paused", %{path: path} do
    first = start_control(path, "be")

    for result <- [{:error, :quota_missing}, {:ok, %{available?: false, summary: "100%"}}, {:ok, %{}}, nil] do
      assert {:ok, %{resume_version: version}} = RuntimeControl.begin_resume(first)
      assert {:ok, %{mode: :paused, reason: reason}} = RuntimeControl.complete_resume(version, result, first)
      assert is_binary(reason)
    end
  end

  test "caller death aborts a manually owned quota check", %{path: path} do
    first = start_control(path, "be")
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:checking, RuntimeControl.begin_resume(first)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:checking, {:ok, %{mode: :checking_quota}}}
    Process.exit(owner, :kill)
    assert_eventually(fn -> match?({:ok, %{mode: :paused}}, RuntimeControl.status(first)) end)
    resume(first)
  end

  test "async resume is bounded and permits another attempt after timeout", %{path: path} do
    parent = self()

    reader = fn ->
      send(parent, {:reader, self()})

      receive do
        :finish -> quota_available()
      end
    end

    first = start_control(path, "be", quota_reader: reader, quota_check_timeout_ms: 80)
    assert {:ok, %{mode: :checking_quota}} = RuntimeControl.resume(first)
    assert_receive {:reader, worker}
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
    assert {:ok, %{mode: :paused, reason: reason}} = RuntimeControl.status(first)
    assert reason =~ "quota_check_timeout"
    assert {:ok, %{mode: :checking_quota}} = RuntimeControl.resume(first)
    assert_receive {:reader, next_worker}
    send(next_worker, :finish)
    assert_eventually(fn -> match?({:ok, %{mode: :running}}, RuntimeControl.status(first)) end)
  end

  test "quota reader crash leaves a retryable pause", %{path: path} do
    first = start_control(path, "be", quota_reader: fn -> exit(:reader_crash) end)
    assert {:ok, %{mode: :checking_quota}} = RuntimeControl.resume(first)
    assert_eventually(fn -> match?({:ok, %{mode: :paused}}, RuntimeControl.status(first)) end)
  end

  test "unavailable members are visible and block resume", %{path: path} do
    first = start_control(path, "be", members: ["be", "fe"])
    assert {:error, {:services_unavailable, ["fe"]}} = RuntimeControl.begin_resume(first)
    second = start_control(path, "fe", members: ["be", "fe"])
    resume(first)
    RuntimeControl.pause("Manual pause", "manual", first)
    stop_control(second)
    assert {:ok, %{services: %{"fe" => %{status: :unknown}}}} = RuntimeControl.status(first)
    assert {:error, {:services_unavailable, ["fe"]}} = RuntimeControl.begin_resume(first)
  end

  test "missing database fails closed and retries survive restart", %{path: path} do
    first = start_control(path, "be")
    retry = %{issue_id: "issue-1", identifier: "SIGN-1", attempt: 2, workspace_path: "/workspaces/SIGN-1"}
    assert :ok = RuntimeControl.persist_retry("be", retry, first)
    stop_control(first)
    second = start_control(path, "be")
    assert {:ok, [%{"issue_id" => "issue-1", "workspace_path" => "/workspaces/SIGN-1"}]} = RuntimeControl.pending_retries("be", second)
    File.rename!(path, path <> ".saved")
    assert {:error, :runtime_database_missing_or_replaced} = RuntimeControl.status(second)
    assert {:error, :runtime_database_missing_or_replaced} = RuntimeControl.acquire_turn(second)
  end

  test "same pause logs one transition", %{path: path} do
    first = start_control(path, "be")

    log =
      capture_log(fn ->
        RuntimeControl.pause("Manual pause", "manual", first)
        RuntimeControl.pause("Manual pause", "manual", first)
      end)

    assert length(Regex.scan(~r/Runtime control changed/, log)) == 1
  end

  test "concurrent identical pauses log a single shared transition", %{path: path} do
    first = start_control(path, "be")
    second = start_control(path, "fe")

    log =
      capture_log(fn ->
        [first, second]
        |> Enum.map(fn server -> Task.async(fn -> RuntimeControl.pause("Manual pause", "manual", server) end) end)
        |> Enum.each(&Task.await/1)
      end)

    assert length(Regex.scan(~r/Runtime control changed/, log)) == 1
  end

  @tag timeout: 60_000
  test "separate BEAM services share pause and drain admission", %{path: path} do
    workflow = path <> ".workflow"
    File.write!(workflow, "---\ntracker:\n  kind: memory\n---\nPrompt\n")
    peers = for id <- ["be", "fe", "landing"], do: start_peer(path, workflow, id)
    [be, fe, landing] = peers
    assert {:ok, %{mode: :checking_quota}} = :peer.call(be, RuntimeControl, :resume, [])
    assert_eventually(fn -> match?({:ok, %{mode: :running}}, :peer.call(fe, RuntimeControl, :status, [])) end)

    {owner, _bindings} =
      :peer.call(fe, Code, :eval_string, ["spawn(fn -> {:ok, token} = SymphonyElixir.RuntimeControl.acquire_turn(); receive do :release -> SymphonyElixir.RuntimeControl.release_turn(token) end end)"])

    assert_eventually(fn -> match?({:ok, %{active_turns: 1}}, :peer.call(be, RuntimeControl, :status, [])) end)
    assert {:ok, %{mode: :pausing}} = :peer.call(landing, RuntimeControl, :pause, ["Shared quota", "quota"])
    assert {:error, :runtime_paused} = :peer.call(be, RuntimeControl, :acquire_turn, [])
    :peer.call(fe, :erlang, :send, [owner, :release])
    assert_eventually(fn -> match?({:ok, %{mode: :paused, active_turns: 0}}, :peer.call(be, RuntimeControl, :status, [])) end)
  end

  defp start_peer(path, workflow, id) do
    args = [~c"+S", ~c"2"] ++ Enum.flat_map(:code.get_path(), fn dir -> [~c"-pa", dir] end)
    {:ok, peer, _node} = :peer.start(%{connection: :standard_io, args: args})
    on_exit(fn -> :peer.stop(peer) end)
    assert {:ok, _apps} = :peer.call(peer, :application, :ensure_all_started, [:elixir])

    script = """
    for app <- [:ecto, :yaml_elixir, :exqlite], do: Application.ensure_all_started(app)
    Application.put_env(:symphony_elixir, :workflow_file_path, #{inspect(workflow)})
    {:ok, store} = SymphonyElixir.WorkflowStore.start_link([])
    Process.unlink(store)
    {:ok, control} = SymphonyElixir.RuntimeControl.start_link(path: #{inspect(path)}, runtime_id: #{inspect(id)},
      members: ["be", "fe", "landing"], quota_reader: fn -> {:ok, %{available?: true, summary: "20%"}} end)
    Process.unlink(control)
    :ok
    """

    assert {:ok, _bindings} = :peer.call(peer, Code, :eval_string, [script], 15_000)
    peer
  end

  defp start_control(path, id, opts \\ []) do
    name = Module.concat(__MODULE__, "Control#{System.unique_integer([:positive])}")
    start_supervised!({RuntimeControl, Keyword.merge([name: name, path: path, runtime_id: id], opts)}, id: name)
    name
  end

  defp stop_control(name), do: stop_supervised!(name)

  defp resume(server) do
    assert {:ok, %{resume_version: version}} = RuntimeControl.begin_resume(server)
    assert {:ok, %{mode: :running}} = RuntimeControl.complete_resume(version, quota_available(), server)
  end

  defp quota_available, do: {:ok, %{available?: true, summary: "codex: 20%"}}

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())
end
