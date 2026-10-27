defmodule SymphonyElixir.RuntimeControl do
  @moduledoc """
  Shared, persistent run/pause control for Symphony instances on one host.

  All enabled service instances must configure the same local SQLite database
  through WORKFLOW runtime_control settings. Each instance owns its connection; SQLite serializes
  the short state transitions across the separate BEAM processes.
  """

  use GenServer
  require Logger

  alias Exqlite.Sqlite3
  alias SymphonyElixir.{Codex.AppServer, Config}

  @retry_open_ms 5_000

  @type status :: %{
          mode: :running | :pausing | :paused | :checking_quota,
          reason: String.t() | nil,
          source: String.t() | nil,
          changed_at: String.t() | nil,
          version: non_neg_integer(),
          active_turns: non_neg_integer(),
          quota_summary: String.t() | nil,
          quota_checked_at: String.t() | nil,
          database_error: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status(GenServer.server()) :: {:ok, status()} | {:error, term()}
  def status(server \\ __MODULE__), do: call(server, :status)

  @spec pause(String.t(), String.t(), GenServer.server()) :: {:ok, status()} | {:error, term()}
  def pause(reason, source \\ "manual", server \\ __MODULE__)
      when is_binary(reason) and is_binary(source) do
    call(server, {:pause, reason, source})
  end

  @spec begin_resume(GenServer.server()) :: {:ok, status()} | {:error, term()}
  def begin_resume(server \\ __MODULE__), do: call(server, :begin_resume)

  @spec resume(GenServer.server()) :: {:ok, status()} | {:error, term()}
  def resume(server \\ __MODULE__), do: call(server, :resume)

  @spec complete_resume(non_neg_integer(), {:ok, map()} | {:error, term()}, GenServer.server()) ::
          {:ok, status()} | {:error, term()}
  def complete_resume(version, quota_result, server \\ __MODULE__) do
    call(server, {:complete_resume, version, quota_result})
  end

  @spec runtime_id() :: String.t()
  def runtime_id, do: :persistent_term.get({__MODULE__, :runtime_id}, "local")

  @spec acquire_turn(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def acquire_turn(server \\ __MODULE__), do: call(server, :acquire_turn)

  @spec release_turn(String.t(), GenServer.server()) :: {:ok, status()} | {:error, term()}
  def release_turn(token, server \\ __MODULE__) when is_binary(token) do
    call(server, {:release_turn, token})
  end

  @spec persist_retry(String.t(), map(), GenServer.server()) :: :ok | {:error, term()}
  def persist_retry(runtime_id, retry, server \\ __MODULE__) when is_binary(runtime_id) and is_map(retry) do
    call(server, {:persist_retry, runtime_id, retry})
  end

  @spec delete_retry(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def delete_retry(runtime_id, issue_id, server \\ __MODULE__)
      when is_binary(runtime_id) and is_binary(issue_id) do
    call(server, {:delete_retry, runtime_id, issue_id})
  end

  @spec pending_retries(String.t(), GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def pending_retries(runtime_id, server \\ __MODULE__) when is_binary(runtime_id) do
    call(server, {:pending_retries, runtime_id})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Config.runtime_control()
    enabled = Keyword.get(opts, :enabled, config.enabled or Keyword.has_key?(opts, :path))
    path = Keyword.get(opts, :path, config.path)
    runtime_id = Keyword.get(opts, :runtime_id, config.id || "local")

    if Keyword.get(opts, :name, __MODULE__) == __MODULE__ do
      :persistent_term.put({__MODULE__, :runtime_id}, runtime_id)
    end

    state = %{
      enabled: enabled,
      conn: nil,
      path: path,
      runtime_id: runtime_id,
      boot_id: boot_id(),
      members: Keyword.get(opts, :members, if(config.members == [], do: [runtime_id], else: config.members)),
      heartbeat_interval_ms: Keyword.get(opts, :heartbeat_interval_ms, config.heartbeat_interval_ms),
      heartbeat_timeout_ms: Keyword.get(opts, :heartbeat_timeout_ms, config.heartbeat_timeout_ms),
      quota_check_timeout_ms: Keyword.get(opts, :quota_check_timeout_ms, config.quota_check_timeout_ms),
      quota_reader: Keyword.get(opts, :quota_reader, &AppServer.read_rate_limits/0),
      resume_check: nil,
      file_identity: nil,
      database_error: nil,
      last_logged_version: 0,
      turn_monitors: %{},
      monitor_tokens: %{}
    }

    if enabled do
      connect_database(state)
    else
      {:ok, state}
    end
  end

  defp connect_database(state) do
    case open_database(state) do
      {:ok, conn} ->
        state = %{state | conn: conn, file_identity: file_identity(state.path), last_logged_version: current_version(conn)}
        state = restore_turn_monitors(state)
        Process.send_after(self(), :heartbeat, state.heartbeat_interval_ms)
        {:ok, state}

      {:error, reason} ->
        Logger.error("Runtime control database unavailable path=#{state.path}: #{inspect(reason)}; dispatch will remain paused")
        Process.send_after(self(), :retry_database_open, @retry_open_ms)
        {:ok, %{state | database_error: inspect(reason)}}
    end
  end

  @impl true
  def handle_call(:runtime_id, _from, state), do: {:reply, state.runtime_id, state}

  def handle_call(request, _from, %{enabled: false} = state) do
    reply = disabled_reply(request)
    {:reply, clean_reply(reply), state}
  end

  def handle_call(:status, _from, state) do
    reply = with_connection(state, fn conn -> transaction(conn, fn -> control_status(conn, state) end) end)
    {:reply, clean_reply(reply), state}
  end

  def handle_call({:pause, reason, source}, _from, state) do
    previous_version = current_version(state)
    reply = with_connection(state, &pause_database(&1, reason, source))
    state = log_control_transition(reply, previous_version, state)
    state = cancel_superseded_check(reply, state)
    {:reply, clean_reply(reply), state}
  end

  def handle_call(:begin_resume, {pid, _tag}, state) do
    {reply, state} = start_resume(state, pid)
    {:reply, clean_reply(reply), state}
  end

  def handle_call(:resume, _from, state) do
    {reply, state} = start_resume(state, nil)
    {:reply, clean_reply(reply), state}
  end

  def handle_call({:complete_resume, version, quota_result}, _from, state) do
    previous_version = current_version(state)
    reply = with_connection(state, &complete_resume_with_members(&1, state, version, quota_result))
    state = finish_resume_check(state, version)
    state = log_control_transition(reply, previous_version, state)
    {:reply, clean_reply(reply), state}
  end

  def handle_call(:acquire_turn, {pid, _tag}, state) do
    token = turn_token(state.runtime_id)
    reply = with_connection(state, &acquire_turn_database(&1, token, state, pid))

    case reply do
      :ok ->
        ref = Process.monitor(pid)

        state = %{
          state
          | turn_monitors: Map.put(state.turn_monitors, token, ref),
            monitor_tokens: Map.put(state.monitor_tokens, ref, token)
        }

        {:reply, {:ok, token}, state}

      _ ->
        {:reply, clean_reply(reply), state}
    end
  end

  def handle_call({:release_turn, token}, _from, state) do
    previous_version = current_version(state)
    reply = with_connection(state, &release_turn_database(&1, token))
    state = if match?({:ok, _}, reply), do: drop_turn_monitor(state, token), else: state
    state = log_control_transition(reply, previous_version, state)
    {:reply, clean_reply(reply), state}
  end

  def handle_call({:persist_retry, runtime_id, retry}, _from, state) do
    reply = with_connection(state, &persist_retry_database(&1, runtime_id, retry))
    {:reply, clean_reply(reply), state}
  end

  def handle_call({:delete_retry, runtime_id, issue_id}, _from, state) do
    reply = with_connection(state, &delete_retry_database(&1, runtime_id, issue_id))
    {:reply, clean_reply(reply), state}
  end

  def handle_call({:pending_retries, runtime_id}, _from, state) do
    reply = with_connection(state, &pending_retries_database(&1, runtime_id))
    {:reply, clean_reply(reply), state}
  end

  @impl true
  def handle_info(:retry_database_open, %{conn: nil} = state) do
    {:ok, state} = connect_database(state)
    {:noreply, state}
  end

  def handle_info(:retry_database_open, state), do: {:noreply, state}

  def handle_info(:heartbeat, state) do
    previous_version = current_version(state)

    reply = with_connection(state, &transaction(&1, fn -> heartbeat_database(&1, state) end))

    Process.send_after(self(), :heartbeat, state.heartbeat_interval_ms)
    state = log_control_transition(reply, previous_version, state)
    {:noreply, cancel_superseded_check(reply, state)}
  end

  def handle_info({:quota_result, version, result}, state) do
    previous_version = current_version(state)
    reply = with_connection(state, &complete_resume_with_members(&1, state, version, result))
    state = finish_resume_check(state, version)
    {:noreply, log_control_transition(reply, previous_version, state)}
  end

  def handle_info({:quota_timeout, version}, state) do
    handle_info({:quota_result, version, {:error, :quota_check_timeout}}, state)
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{resume_check: %{ref: ref, version: version}} = state) do
    handle_info({:quota_result, version, {:error, {:quota_check_interrupted, reason}}}, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitor_tokens, ref) do
      {nil, _monitor_tokens} ->
        {:noreply, state}

      {token, _monitor_tokens} ->
        previous_version = current_version(state)
        reply = with_connection(state, &release_turn_database(&1, token))
        state = if match?({:ok, _}, reply), do: drop_turn_monitor(state, token), else: state
        state = log_control_transition(reply, previous_version, state)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn} = state) when not is_nil(conn) do
    if state.resume_check, do: finish_resume_check(state, state.resume_check.version)
    execute(conn, "UPDATE runtime_services SET last_seen = 0 WHERE runtime_id = ?1", [state.runtime_id])
    Sqlite3.close(conn)
  end

  def terminate(_reason, _state), do: :ok

  defp open_database(%{path: path} = state) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, conn} <- Sqlite3.open(path) do
      case initialize_database(conn, state) do
        :ok ->
          {:ok, conn}

        {:error, reason} ->
          Sqlite3.close(conn)
          {:error, reason}
      end
    end
  rescue
    exception -> {:error, {:database_exception, Exception.message(exception)}}
  end

  defp initialize_database(conn, state) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout = 1000"),
         :ok <- enable_wal(conn),
         :ok <- create_schema(conn) do
      initialize_runtime(conn, state)
    end
  end

  defp create_schema(conn) do
    with :ok <-
           Sqlite3.execute(
             conn,
             "CREATE TABLE IF NOT EXISTS runtime_control (id INTEGER PRIMARY KEY CHECK (id = 1), mode TEXT NOT NULL, reason TEXT, source TEXT, changed_at TEXT, version INTEGER NOT NULL DEFAULT 0, quota_summary TEXT, quota_checked_at TEXT)"
           ),
         :ok <-
           Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS turn_owners (token TEXT PRIMARY KEY, boot_id TEXT NOT NULL, owner TEXT NOT NULL)"),
         :ok <-
           Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS runtime_services (runtime_id TEXT PRIMARY KEY, boot_id TEXT NOT NULL, last_seen INTEGER NOT NULL)"),
         :ok <-
           Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS quota_checks (version INTEGER PRIMARY KEY, runtime_id TEXT NOT NULL, deadline INTEGER NOT NULL)"),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE TABLE IF NOT EXISTS active_turns (token TEXT PRIMARY KEY, runtime_id TEXT NOT NULL, started_at TEXT NOT NULL)"
           ),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE TABLE IF NOT EXISTS pending_retries (runtime_id TEXT NOT NULL, issue_id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (runtime_id, issue_id))"
           ) do
      execute(
        conn,
        "INSERT OR IGNORE INTO runtime_control (id, mode, reason, source, changed_at, version) VALUES (1, 'paused', 'Runtime control initialized; check quota before resuming', 'system', ?1, 0)",
        [DateTime.utc_now() |> DateTime.to_iso8601()]
      )
    end
  end

  defp initialize_runtime(conn, state) do
    case transaction(conn, fn -> initialize_runtime_database(conn, state) end) do
      {:ok, status} ->
        if status[:transition_changed?] do
          Logger.warning("Runtime control recovered after service restart mode=#{status.mode} reason=#{inspect(status.reason)}")
        end

        :ok

      error ->
        error
    end
  end

  defp initialize_runtime_database(conn, state) do
    with :ok <- check_runtime_owner(conn, state),
         :ok <- reap_local_turns(conn, state),
         :ok <- recover_owned_quota_check(conn, state.runtime_id),
         :ok <- expire_quota_check(conn),
         :ok <- record_heartbeat(conn, state) do
      complete_drain_if_idle(conn)
    end
  end

  defp heartbeat_database(conn, state) do
    with :ok <- record_heartbeat(conn, state),
         :ok <- reap_local_turns(conn, state),
         :ok <- expire_quota_check(conn),
         {:ok, _status} <- complete_drain_if_idle(conn) do
      control_status(conn, state)
    end
  end

  defp read_status(conn) do
    with {:ok, [mode, reason, source, changed_at, version, quota_summary, quota_checked_at]} <-
           query_one(conn, "SELECT mode, reason, source, changed_at, version, quota_summary, quota_checked_at FROM runtime_control WHERE id = 1"),
         {:ok, [active_turns]} <- query_one(conn, "SELECT COUNT(*) FROM active_turns") do
      {:ok,
       %{
         mode: parse_mode(mode),
         reason: reason,
         source: source,
         changed_at: changed_at,
         version: version,
         active_turns: active_turns,
         quota_summary: quota_summary,
         quota_checked_at: quota_checked_at,
         database_error: nil
       }}
    end
  end

  defp pause_database(conn, reason, source) do
    transaction(conn, fn -> pause_in_transaction(conn, reason, source) end)
  end

  defp pause_in_transaction(conn, reason, source) do
    with {:ok, [current_mode, current_reason, current_source]} <-
           query_one(conn, "SELECT mode, reason, source FROM runtime_control WHERE id = 1"),
         {:ok, [active_turns]} <- query_one(conn, "SELECT COUNT(*) FROM active_turns") do
      if current_mode in ["paused", "pausing"] and current_reason == reason and current_source == source do
        read_status(conn)
      else
        update_pause(conn, reason, source, active_turns)
      end
    end
  end

  defp update_pause(conn, reason, source, active_turns) do
    mode = if active_turns > 0, do: "pausing", else: "paused"

    with :ok <-
           execute(
             conn,
             "UPDATE runtime_control SET mode = ?1, reason = ?2, source = ?3, changed_at = ?4, version = version + 1 WHERE id = 1",
             [mode, reason, source, DateTime.utc_now() |> DateTime.to_iso8601()]
           ) do
      read_status(conn)
    end
  end

  defp begin_resume_database(conn, state) do
    transaction(conn, fn ->
      with {:ok, [mode, version]} <- query_one(conn, "SELECT mode, version FROM runtime_control WHERE id = 1"),
           true <- mode == "paused",
           :ok <- require_online_members(conn, state),
           :ok <-
             execute(
               conn,
               "UPDATE runtime_control SET mode = 'checking_quota', reason = 'Checking Codex quota', source = 'resume', changed_at = ?1, version = version + 1 WHERE id = 1",
               [DateTime.utc_now() |> DateTime.to_iso8601()]
             ),
           :ok <- execute(conn, "INSERT INTO quota_checks (version, runtime_id, deadline) VALUES (?1, ?2, ?3)", [version + 1, state.runtime_id, now_ms() + state.quota_check_timeout_ms]),
           {:ok, status} <- read_status(conn) do
        {:ok, Map.put(status, :resume_version, version + 1)}
      else
        false -> {:error, :not_paused}
        {:ok, status} -> {:error, {:cannot_resume_from, status.mode}}
        other -> other
      end
    end)
  end

  defp complete_resume_database(conn, expected_version, quota_result) do
    transaction(conn, fn -> complete_resume_in_transaction(conn, expected_version, quota_result) end)
  end

  defp complete_resume_in_transaction(conn, expected_version, quota_result) do
    with {:ok, [mode, version]} <- query_one(conn, "SELECT mode, version FROM runtime_control WHERE id = 1"),
         true <- mode == "checking_quota" and version == expected_version do
      with {:ok, status} <- complete_resume_transition(conn, quota_result),
           :ok <- execute(conn, "DELETE FROM quota_checks WHERE version = ?1", [expected_version]) do
        {:ok, status}
      end
    else
      false -> {:error, :resume_superseded}
      other -> other
    end
  end

  defp complete_resume_transition(conn, {:ok, %{available?: true} = quota}) do
    update_control(conn, "running", nil, "resume", quota_summary(quota), DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp complete_resume_transition(conn, {:ok, %{available?: false} = quota}) do
    summary = quota_summary(quota)
    update_control(conn, "paused", "Codex quota is still exhausted: #{summary}", "quota", summary, DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp complete_resume_transition(conn, {:error, reason}) do
    summary = "Unavailable: #{inspect(reason)}"
    update_control(conn, "paused", "Unable to verify Codex quota: #{inspect(reason)}", "quota_check", summary, DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp complete_resume_transition(conn, other) do
    summary = "Unavailable: invalid response #{inspect(other)}"
    update_control(conn, "paused", "Unable to verify Codex quota: invalid response #{inspect(other)}", "quota_check", summary, DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp update_control(conn, mode, reason, source, quota_summary, quota_checked_at) do
    with :ok <-
           execute(
             conn,
             "UPDATE runtime_control SET mode = ?1, reason = ?2, source = ?3, changed_at = ?4, version = version + 1, quota_summary = ?5, quota_checked_at = ?6 WHERE id = 1",
             [mode, reason, source, DateTime.utc_now() |> DateTime.to_iso8601(), quota_summary, quota_checked_at]
           ) do
      read_status(conn)
    end
  end

  defp acquire_turn_database(conn, token, state, pid) do
    transaction(conn, fn ->
      with {:ok, [mode]} <- query_one(conn, "SELECT mode FROM runtime_control WHERE id = 1"),
           true <- mode == "running",
           :ok <-
             execute(
               conn,
               "INSERT INTO active_turns (token, runtime_id, started_at) VALUES (?1, ?2, ?3)",
               [token, state.runtime_id, DateTime.utc_now() |> DateTime.to_iso8601()]
             ),
           :ok <- execute(conn, "INSERT INTO turn_owners (token, boot_id, owner) VALUES (?1, ?2, ?3)", [token, state.boot_id, Base.encode64(:erlang.term_to_binary(pid))]) do
        :ok
      else
        false -> {:error, :runtime_paused}
        other -> other
      end
    end)
  end

  defp release_turn_database(conn, token) do
    transaction(conn, fn ->
      with :ok <- execute(conn, "DELETE FROM active_turns WHERE token = ?1", [token]) do
        execute(conn, "DELETE FROM turn_owners WHERE token = ?1", [token])
        complete_drain_if_idle(conn)
      end
    end)
  end

  defp complete_drain_if_idle(conn) do
    with {:ok, [mode]} <- query_one(conn, "SELECT mode FROM runtime_control WHERE id = 1"),
         {:ok, [active_turns]} <- query_one(conn, "SELECT COUNT(*) FROM active_turns"),
         :ok <- finish_drain_update(conn, mode, active_turns) do
      read_status(conn)
    end
  end

  defp finish_drain_update(conn, "pausing", 0) do
    execute(
      conn,
      "UPDATE runtime_control SET mode = 'paused', changed_at = ?1, version = version + 1 WHERE id = 1",
      [DateTime.utc_now() |> DateTime.to_iso8601()]
    )
  end

  defp finish_drain_update(_conn, _mode, _active_turns), do: :ok

  defp persist_retry_database(conn, runtime_id, retry) do
    payload =
      retry
      |> Map.take([:issue_id, :identifier, :issue_url, :attempt, :error, :worker_host, :workspace_path, :session_unit, :session_invocation, :infrastructure_failures, :retry_priority])
      |> atom_keys_to_strings()
      |> Jason.encode()

    with {:ok, json} <- payload do
      execute(
        conn,
        "INSERT INTO pending_retries (runtime_id, issue_id, payload) VALUES (?1, ?2, ?3) ON CONFLICT(runtime_id, issue_id) DO UPDATE SET payload = excluded.payload",
        [runtime_id, retry.issue_id, json]
      )
    end
  end

  defp delete_retry_database(conn, runtime_id, issue_id) do
    execute(conn, "DELETE FROM pending_retries WHERE runtime_id = ?1 AND issue_id = ?2", [runtime_id, issue_id])
  end

  defp pending_retries_database(conn, runtime_id) do
    with {:ok, statement} <- Sqlite3.prepare(conn, "SELECT payload FROM pending_retries WHERE runtime_id = ?1 ORDER BY issue_id"),
         :ok <- Sqlite3.bind(statement, [runtime_id]) do
      try do
        collect_retries(conn, statement, [])
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp collect_retries(conn, statement, retries) do
    case Sqlite3.step(conn, statement) do
      {:row, [json]} ->
        case Jason.decode(json) do
          {:ok, retry} -> collect_retries(conn, statement, [retry | retries])
          {:error, reason} -> {:error, {:invalid_retry_record, reason}}
        end

      :done ->
        {:ok, Enum.reverse(retries)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp with_connection(%{conn: nil, database_error: reason}, _fun), do: {:error, {:database_unavailable, reason}}

  defp with_connection(%{conn: conn} = state, fun) do
    if file_identity(state.path) == state.file_identity and not is_nil(state.file_identity) do
      fun.(conn)
    else
      {:error, :runtime_database_missing_or_replaced}
    end
  rescue
    exception -> {:error, {:database_exception, Exception.message(exception)}}
  end

  defp transaction(conn, fun) do
    with :ok <- Sqlite3.execute(conn, "BEGIN IMMEDIATE") do
      previous_version = current_version(conn)

      try do
        case fun.() do
          {:error, _reason} = error ->
            Sqlite3.execute(conn, "ROLLBACK")
            error

          result ->
            case Sqlite3.execute(conn, "COMMIT") do
              :ok ->
                mark_transition(result, previous_version)

              {:error, reason} ->
                Sqlite3.execute(conn, "ROLLBACK")
                {:error, reason}
            end
        end
      rescue
        exception ->
          Sqlite3.execute(conn, "ROLLBACK")
          {:error, {:database_exception, Exception.message(exception)}}
      end
    end
  end

  defp execute(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql),
         :ok <- Sqlite3.bind(statement, params) do
      try do
        case Sqlite3.step(conn, statement) do
          :done -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_sqlite_step, other}}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp query_one(conn, sql) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        case Sqlite3.step(conn, statement) do
          {:row, values} -> {:ok, values}
          :done -> {:error, :no_rows}
          {:error, reason} -> {:error, reason}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp log_control_transition({:ok, status}, previous_version, state)
       when is_integer(previous_version) and is_map_key(status, :transition_changed?) and status.transition_changed? do
    Logger.warning("Runtime control changed mode=#{status.mode} source=#{inspect(status.source)} reason=#{inspect(status.reason)} active_turns=#{status.active_turns}")

    %{state | last_logged_version: max(state.last_logged_version, status.version)}
  end

  defp log_control_transition(_reply, _previous_version, state), do: state

  defp mark_transition({:ok, %{version: version} = status}, previous_version) do
    {:ok, Map.put(status, :transition_changed?, version > previous_version)}
  end

  defp mark_transition(result, _previous_version), do: result

  defp clean_reply({:ok, status}) when is_map(status), do: {:ok, Map.delete(status, :transition_changed?)}
  defp clean_reply(reply), do: reply

  defp drop_turn_monitor(state, token) do
    case Map.pop(state.turn_monitors, token) do
      {nil, _turn_monitors} ->
        state

      {ref, turn_monitors} ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | turn_monitors: turn_monitors,
            monitor_tokens: Map.delete(state.monitor_tokens, ref)
        }
    end
  end

  defp current_version(%{conn: nil}), do: nil
  defp current_version(%{conn: conn}), do: current_version(conn)

  defp current_version(conn) do
    case query_one(conn, "SELECT version FROM runtime_control WHERE id = 1") do
      {:ok, [version]} -> version
      _ -> 0
    end
  end

  defp enable_wal(conn) do
    with {:ok, statement} <- Sqlite3.prepare(conn, "PRAGMA journal_mode = WAL") do
      try do
        case Sqlite3.step(conn, statement) do
          {:row, ["wal"]} -> :ok
          {:row, [mode]} -> {:error, {:unsupported_sqlite_journal_mode, mode}}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_sqlite_step, other}}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp parse_mode("running"), do: :running
  defp parse_mode("pausing"), do: :pausing
  defp parse_mode("checking_quota"), do: :checking_quota
  defp parse_mode(_), do: :paused

  defp turn_token(runtime_id) do
    "#{runtime_id}:#{System.unique_integer([:positive, :monotonic])}:#{System.system_time(:nanosecond)}"
  end

  defp quota_summary(%{summary: summary}) when is_binary(summary), do: summary
  defp quota_summary(_quota), do: "quota available"

  defp atom_keys_to_strings(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp call(server, request) do
    GenServer.call(server, request, 10_000)
  catch
    :exit, reason -> {:error, {:runtime_control_unavailable, reason}}
  end

  defp disabled_reply(:pending_retries), do: {:ok, []}
  defp disabled_reply({:pending_retries, _id}), do: {:ok, []}
  defp disabled_reply({:persist_retry, _id, _retry}), do: :ok
  defp disabled_reply({:delete_retry, _id, _issue}), do: :ok
  defp disabled_reply(:acquire_turn), do: {:ok, "disabled"}
  defp disabled_reply({:release_turn, _token}), do: {:ok, disabled_status()}
  defp disabled_reply(:status), do: {:ok, disabled_status()}
  defp disabled_reply(_request), do: {:error, :runtime_control_disabled}

  defp disabled_status do
    %{
      enabled: false,
      mode: :running,
      reason: nil,
      source: nil,
      changed_at: nil,
      version: 0,
      active_turns: 0,
      quota_summary: nil,
      quota_checked_at: nil,
      database_error: nil,
      services: %{}
    }
  end

  defp file_identity(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, inode: inode, major_device: device}} -> {device, inode}
      _ -> nil
    end
  end

  defp boot_id do
    key = {__MODULE__, :boot_id}

    case :persistent_term.get(key, nil) do
      nil ->
        id = Base.encode64(:crypto.strong_rand_bytes(24))
        :persistent_term.put(key, id)
        id

      id ->
        id
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp record_heartbeat(conn, state) do
    execute(
      conn,
      "INSERT INTO runtime_services (runtime_id, boot_id, last_seen) VALUES (?1, ?2, ?3) ON CONFLICT(runtime_id) DO UPDATE SET boot_id = excluded.boot_id, last_seen = excluded.last_seen",
      [state.runtime_id, state.boot_id, now_ms()]
    )
  end

  defp check_runtime_owner(conn, state) do
    with {:ok, rows} <- query_rows(conn, "SELECT boot_id, last_seen FROM runtime_services WHERE runtime_id = ?1", [state.runtime_id]) do
      runtime_owner_available(rows, state)
    end
  end

  defp runtime_owner_available([[boot_id, last_seen]], state) when boot_id != state.boot_id do
    if now_ms() - last_seen <= state.heartbeat_timeout_ms, do: {:error, :runtime_id_already_online}, else: :ok
  end

  defp runtime_owner_available(_rows, _state), do: :ok

  defp local_turns(conn, id) do
    query_rows(conn, "SELECT a.token, o.boot_id, o.owner FROM active_turns a LEFT JOIN turn_owners o ON a.token = o.token WHERE a.runtime_id = ?1", [id])
  end

  defp live_owner([_token, boot_id, encoded], state) when boot_id == state.boot_id and is_binary(encoded) do
    pid = encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    if is_pid(pid) and node(pid) == node() and Process.alive?(pid), do: pid, else: nil
  rescue
    _exception -> nil
  end

  defp live_owner(_row, _state), do: nil

  defp reap_local_turns(conn, state) do
    with {:ok, rows} <- local_turns(conn, state.runtime_id) do
      Enum.reduce_while(rows, :ok, fn row, :ok -> reduce_result(reap_turn(conn, row, state)) end)
    end
  end

  defp reap_turn(conn, [token, _boot, _owner] = row, state) do
    if live_owner(row, state) do
      :ok
    else
      with :ok <- execute(conn, "DELETE FROM active_turns WHERE token = ?1", [token]) do
        execute(conn, "DELETE FROM turn_owners WHERE token = ?1", [token])
      end
    end
  end

  defp reduce_result(:ok), do: {:cont, :ok}
  defp reduce_result(error), do: {:halt, error}

  defp restore_turn_monitors(state) do
    case local_turns(state.conn, state.runtime_id) do
      {:ok, rows} ->
        Enum.reduce(rows, state, &restore_turn_monitor/2)

      _ ->
        state
    end
  end

  defp restore_turn_monitor([token, _boot, _owner] = row, state) do
    case live_owner(row, state) do
      nil ->
        state

      pid ->
        ref = Process.monitor(pid)
        %{state | turn_monitors: Map.put(state.turn_monitors, token, ref), monitor_tokens: Map.put(state.monitor_tokens, ref, token)}
    end
  end

  defp control_status(conn, state) do
    with {:ok, status} <- read_status(conn),
         {:ok, rows} <- query_rows(conn, "SELECT runtime_id, last_seen FROM runtime_services", []) do
      seen = Map.new(rows, fn [id, last_seen] -> {id, last_seen} end)

      services =
        Map.new(state.members, fn id ->
          last_seen = Map.get(seen, id)
          online = is_integer(last_seen) and last_seen > 0 and now_ms() - last_seen <= state.heartbeat_timeout_ms
          {id, %{status: if(online, do: :online, else: :unknown), last_seen: last_seen}}
        end)

      {:ok, Map.merge(status, %{enabled: true, services: services})}
    end
  end

  defp require_online_members(conn, state) do
    with {:ok, status} <- control_status(conn, state) do
      unknown = for {id, %{status: :unknown}} <- status.services, do: id
      if unknown == [], do: :ok, else: {:error, {:services_unavailable, Enum.sort(unknown)}}
    end
  end

  defp recover_owned_quota_check(conn, id) do
    with {:ok, rows} <- query_rows(conn, "SELECT version FROM quota_checks WHERE runtime_id = ?1", [id]) do
      recover_checks(conn, rows, :quota_check_interrupted_by_restart)
    end
  end

  defp expire_quota_check(conn) do
    with {:ok, rows} <- query_rows(conn, "SELECT version FROM quota_checks WHERE deadline <= ?1", [now_ms()]) do
      recover_checks(conn, rows, :quota_check_timeout)
    end
  end

  defp recover_checks(conn, rows, reason) do
    Enum.reduce_while(rows, :ok, fn [version], :ok -> reduce_result(recover_check(conn, version, reason)) end)
  end

  defp recover_check(conn, version, reason) do
    case complete_resume_in_transaction(conn, version, {:error, reason}) do
      {:ok, _} -> :ok
      {:error, :resume_superseded} -> execute(conn, "DELETE FROM quota_checks WHERE version = ?1", [version])
      error -> error
    end
  end

  defp complete_resume_with_members(conn, state, version, {:ok, %{available?: true}} = result) do
    case require_online_members(conn, state) do
      :ok -> complete_resume_database(conn, version, result)
      {:error, _} = error -> complete_resume_database(conn, version, error)
    end
  end

  defp complete_resume_with_members(conn, _state, version, result), do: complete_resume_database(conn, version, result)

  defp start_resume(state, caller) do
    previous_version = current_version(state)
    reply = with_connection(state, &begin_resume_database(&1, state))
    state = log_control_transition(reply, previous_version, state)

    case reply do
      {:ok, %{resume_version: version}} ->
        control = self()
        reader = state.quota_reader

        {pid, worker?} =
          if caller do
            {caller, false}
          else
            {spawn_link(fn -> send(control, {:quota_result, version, read_quota(reader)}) end), true}
          end

        ref = Process.monitor(pid)
        timer = Process.send_after(self(), {:quota_timeout, version}, state.quota_check_timeout_ms)
        {reply, %{state | resume_check: %{version: version, pid: pid, ref: ref, timer: timer, worker?: worker?}}}

      _ ->
        {reply, state}
    end
  end

  defp read_quota(reader) do
    reader.()
  rescue
    exception -> {:error, {:quota_check_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:quota_check_failed, {kind, reason}}}
  end

  defp finish_resume_check(%{resume_check: %{version: version} = check} = state, version) do
    Process.cancel_timer(check.timer)
    Process.demonitor(check.ref, [:flush])
    if check.worker? and Process.alive?(check.pid), do: Process.exit(check.pid, :kill)
    %{state | resume_check: nil}
  end

  defp finish_resume_check(state, _version), do: state

  defp cancel_superseded_check({:ok, %{mode: mode, version: version}}, %{resume_check: check} = state)
       when not is_nil(check) do
    if mode != :checking_quota or version != check.version, do: finish_resume_check(state, check.version), else: state
  end

  defp cancel_superseded_check(_reply, state), do: state

  defp query_rows(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql), :ok <- Sqlite3.bind(statement, params) do
      try do
        collect_rows(conn, statement, [])
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp collect_rows(conn, statement, rows) do
    case Sqlite3.step(conn, statement) do
      {:row, row} -> collect_rows(conn, statement, [row | rows])
      :done -> {:ok, Enum.reverse(rows)}
      {:error, _} = error -> error
      other -> {:error, {:unexpected_sqlite_step, other}}
    end
  end
end
