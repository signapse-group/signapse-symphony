defmodule SymphonyElixir.Codex.SessionProcess do
  @moduledoc false

  require Logger
  alias SymphonyElixir.{Config, Profile, SSH, Tracker}

  @external_resource Path.expand("../../../priv/codex_session.py", __DIR__)
  @script @external_resource |> File.read!() |> Base.encode64()
  @decoder "import base64,sys;exec(base64.b64decode(sys.argv[1]))"

  @spec new() :: map()
  def new do
    %{unit: "symphony-session-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}.service", invocation: nil}
  end

  @spec launch_command(map(), String.t(), String.t(), keyword()) :: String.t()
  def launch_command(identity, command, workspace, opts \\ []) do
    shell_arg = if Keyword.get(opts, :login, true), do: "-lc", else: "-c"
    mode = Keyword.get(opts, :mode, "session")
    command("launch", identity, [command, workspace, shell_arg, opts[:instructions_root] || "", mode])
  end

  @doc false
  @spec run_hook(String.t(), Path.t(), map(), list(), pos_integer()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run_hook(command, workspace, snapshot, env, timeout) do
    identity = new()
    on_started = snapshot.hook_started
    on_stopped = snapshot.hook_stopped
    launch_opts = [login: false, mode: "hook", instructions_root: get_in(Map.get(snapshot, :instructions), [:root])]
    launch = launch_command(identity, command, workspace, launch_opts)
    session = %{containment: identity, worker_host: nil, profile_snapshot: snapshot, heartbeat: nil, recovered: true}

    with :ok <- on_started.(session) do
      result = run_registered_hook(launch, env, session, on_started, timeout)

      finish_hook(result, on_stopped)
    end
  end

  defp finish_hook({:error, {:session_stop_unconfirmed, _reason}} = error, _on_stopped), do: error

  defp finish_hook(result, on_stopped) do
    with :ok <- on_stopped.(), do: result
  end

  defp run_registered_hook(launch, env, session, on_started, timeout) do
    env =
      env
      |> Enum.reject(fn {name, _value} -> name == "BASH_ENV" end)
      |> Kernel.++([{"BASH_ENV", nil}])
      |> Enum.map(fn {name, value} -> {String.to_charlist(name), if(is_binary(value), do: String.to_charlist(value), else: false)} end)

    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      shell ->
        port_opts = [:binary, :exit_status, :stderr_to_stdout, args: ["-c", launch], env: env, line: 1_048_576]
        port = Port.open({:spawn_executable, shell}, port_opts)

        try do
          deadline = System.monotonic_time(:millisecond) + timeout
          read_hook(port, %{session | heartbeat: heartbeat(port, nil)}, on_started, deadline)
        after
          if Port.info(port), do: Port.close(port)
        end
    end
  end

  defp read_hook(port, session, on_started, deadline) do
    receive do
      {^port, {:data, {:eol, "SYMPHONY_CGROUP:" <> invocation}}} ->
        start_hook(port, session, invocation, on_started, deadline)

      {^port, {:exit_status, _status}} ->
        stop_hook(session, {:error, :hook_containment_start_failed})
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        stop_hook(session, {:error, :hook_timeout})
    end
  end

  defp start_hook(port, session, invocation, on_started, deadline) do
    if String.match?(invocation, ~r/^[0-9a-f]{32}$/) do
      session = put_in(session.containment.invocation, invocation)

      result =
        with :ok <- on_started.(session) do
          true = Port.command(port, "SYMPHONY_START\n")
          collect_hook_output(port, deadline, [])
        end

      stop_hook(session, result)
    else
      stop_hook(session, {:error, :invalid_hook_containment})
    end
  end

  defp collect_hook_output(port, deadline, output) do
    receive do
      {^port, {:data, {:eol, chunk}}} -> collect_hook_output(port, deadline, ["\n", chunk | output])
      {^port, {:data, {:noeol, chunk}}} -> collect_hook_output(port, deadline, [chunk | output])
      {^port, {:exit_status, status}} -> {:ok, {IO.iodata_to_binary(Enum.reverse(output)), status}}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :hook_timeout}
    end
  end

  defp stop_hook(session, result) do
    case stop(session) do
      :ok -> result
      error -> error
    end
  end

  @spec heartbeat(port(), pid() | nil) :: pid()
  def heartbeat(port, lifecycle_owner) do
    owner = self()

    spawn(fn ->
      Process.monitor(owner)
      if is_pid(lifecycle_owner) and lifecycle_owner != owner, do: Process.monitor(lifecycle_owner)
      heartbeat_loop(port)
    end)
  end

  defp heartbeat_loop(port) do
    receive do
      :stop -> :ok
      {:DOWN, _ref, :process, _pid, _reason} -> :ok
    after
      1_000 ->
        true = Port.command(port, "SYMPHONY_HEARTBEAT\n")
        heartbeat_loop(port)
    end
  rescue
    ArgumentError -> :ok
  end

  @spec stop(map()) :: :ok | {:error, term()}
  def stop(%{containment: %{unit: unit, invocation: invocation}, worker_host: host} = session)
      when is_binary(unit) and (is_nil(invocation) or is_binary(invocation)) and (is_nil(host) or is_binary(host)) do
    stop_session_process(session)
  end

  def stop(_session), do: {:error, :session_process_unknown}

  defp stop_session_process(%{containment: identity, worker_host: host} = session) do
    if is_pid(session[:heartbeat]), do: send(session.heartbeat, :stop)
    args = stop_args(identity.invocation, session[:recovered])
    shell_command = command("stop", identity, args)

    {shell_arg, env_opts, read_timeout} = stop_options(session[:profile_snapshot])

    task =
      Task.async(fn ->
        try do
          run_stop_command(host, shell_arg, shell_command, env_opts)
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    # Query, kill and population checks each allow 5s; leave room for bounded diagnostics.
    timeout = max(read_timeout, 17_000)
    result = Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)

    case result do
      {:ok, {:ok, {_, 0}}} ->
        :ok

      other ->
        Logger.error("Codex session stop unconfirmed session_unit=#{identity.unit} diagnostic=#{stop_diagnostic(other, identity.unit)}")
        {:error, {:session_stop_unconfirmed, other}}
    end
  end

  defp stop_args(nil, true), do: ["", "prestart"]
  defp stop_args(invocation, _recovered), do: [invocation || ""]

  defp run_stop_command(nil, shell_arg, command, env_opts),
    do: {:ok, System.cmd("bash", [shell_arg, command], [stderr_to_stdout: true] ++ env_opts)}

  defp run_stop_command(host, _shell_arg, command, _env_opts), do: SSH.run(host, command, stderr_to_stdout: true)

  defp stop_options(nil), do: {"-c", [], Config.settings!().codex.read_timeout_ms}

  defp stop_options(%{settings: settings} = snapshot) do
    binding = Tracker.bind_agent_tools(settings.tracker)
    env = Profile.subprocess_env(snapshot, binding.secret_environment_names ++ ["BASH_ENV"])
    {"-c", [env: env], settings.codex.read_timeout_ms}
  end

  defp stop_diagnostic({:ok, {:ok, {output, _status}}}, unit) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.find_value("unavailable", fn
      <<"SYMPHONY_SESSION_STOP ", json::binary>> when byte_size(json) <= 4_096 ->
        case Jason.decode(json) do
          {:ok, %{"unit" => ^unit}} -> json
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp stop_diagnostic(_result, _unit), do: "unavailable"

  defp command(mode, identity, args) do
    ["python3", "-u", "-c", @decoder, @script, mode, identity.unit | args]
    |> Enum.map_join(" ", &shell_escape/1)
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
