defmodule SymphonyElixir.Codex.SessionProcess do
  @moduledoc false

  require Logger
  alias SymphonyElixir.{Config, SSH}

  @external_resource Path.expand("../../../priv/codex_session.py", __DIR__)
  @script @external_resource |> File.read!() |> Base.encode64()
  @decoder "import base64,sys;exec(base64.b64decode(sys.argv[1]))"

  @spec new() :: map()
  def new do
    %{unit: "symphony-session-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}.service", invocation: nil}
  end

  @spec launch_command(map(), String.t(), String.t()) :: String.t()
  def launch_command(identity, command, workspace), do: command("launch", identity, [command, workspace])

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
    shell_command = command("stop", identity, [identity.invocation || ""])

    task =
      Task.async(fn ->
        try do
          if is_binary(host),
            do: SSH.run(host, shell_command, stderr_to_stdout: true),
            else: {:ok, System.cmd("bash", ["-c", shell_command], stderr_to_stdout: true)}
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    # Query, kill and population checks each allow 5s; leave room for bounded diagnostics.
    timeout = max(Config.settings!().codex.read_timeout_ms, 17_000)
    result = Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)

    case result do
      {:ok, {:ok, {_, 0}}} ->
        :ok

      other ->
        Logger.error("Codex session stop unconfirmed session_unit=#{identity.unit} diagnostic=#{stop_diagnostic(other, identity.unit)}")
        {:error, {:session_stop_unconfirmed, other}}
    end
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
