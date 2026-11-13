defmodule SymphonyElixir.AssignmentOwners do
  @moduledoc false

  use GenServer
  alias Exqlite.Sqlite3

  @type key :: {String.t(), String.t(), String.t()}
  @type owner :: {String.t(), Path.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :path), name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec claim(key(), owner(), GenServer.server()) :: :ok | {:error, term()}
  def claim(key, owner, server \\ __MODULE__), do: call(server, {:claim, key, owner})

  @spec owner(key(), GenServer.server()) :: {:ok, owner() | nil} | {:error, term()}
  def owner(key, server \\ __MODULE__), do: call(server, {:owner, key})

  @spec foreign_assignments(map(), owner(), [String.t()]) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def foreign_assignments(%{base_url: base, project_key: project}, {profile, root}, ids) do
    call(__MODULE__, {:foreign_assignments, base, project, profile, root, Jason.encode!(ids)})
  end

  @spec ready(map()) :: :ok | {:error, term()}
  def ready(%{base_url: base, project_key: project}), do: call(__MODULE__, {:ready, base, project})

  @impl true
  def init(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, conn} <- Sqlite3.open(path) do
      case initialize(conn) do
        :ok -> {:ok, %{conn: conn, path: path, identity: identity(path)}}
        {:error, _reason} -> {:stop, :assignment_database_unavailable}
      end
    else
      {:error, _reason} -> {:stop, :assignment_database_unavailable}
    end
  end

  @impl true
  def handle_call(request, _from, state) do
    reply =
      if state.identity && state.identity == identity(state.path),
        do: execute_request(state.conn, request),
        else: {:error, :assignment_database_replaced}

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.conn)

  defp initialize(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout = 1000"),
         :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode = WAL") do
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS assignment_owners (
        tracker_base_url TEXT NOT NULL,
        project_key TEXT NOT NULL,
        issue_id TEXT NOT NULL,
        profile_id TEXT NOT NULL,
        workspace_root TEXT NOT NULL,
        PRIMARY KEY (tracker_base_url, project_key, issue_id)
      )
      """)
    end
  end

  defp execute_request(conn, {:claim, {base, project, id} = key, {profile, root} = owner}) do
    sql = """
    INSERT INTO assignment_owners SELECT ?1, ?2, ?3, ?4, ?5
    WHERE NOT EXISTS (SELECT 1 FROM assignment_owners WHERE tracker_base_url != ?1 OR project_key != ?2)
    ON CONFLICT DO NOTHING
    """

    with :done <- step(conn, sql, [base, project, id, profile, root]),
         {:ok, ^owner} <- execute_request(conn, {:owner, key}) do
      :ok
    else
      {:ok, nil} -> {:error, :assignment_authority_changed}
      {:ok, {^profile, _other_root}} -> {:error, :assignment_workspace_changed}
      {:ok, _other_owner} -> {:error, :assignment_owned_by_other_profile}
      {:error, _} -> {:error, :assignment_database_unavailable}
    end
  end

  defp execute_request(conn, {:owner, {base, project, id}}) do
    sql = "SELECT profile_id, workspace_root FROM assignment_owners WHERE tracker_base_url = ?1 AND project_key = ?2 AND issue_id = ?3"

    case step(conn, sql, [base, project, id]) do
      {:row, [profile, root]} -> {:ok, {profile, root}}
      :done -> {:ok, nil}
      {:error, _reason} -> {:error, :assignment_database_unavailable}
    end
  end

  defp execute_request(conn, {:ready, base, project}) do
    case step(conn, "SELECT 1 FROM assignment_owners WHERE tracker_base_url != ?1 OR project_key != ?2 LIMIT 1", [base, project]) do
      {:error, _reason} -> {:error, :assignment_database_unavailable}
      {:row, _} -> {:error, :assignment_authority_changed}
      :done -> :ok
    end
  end

  defp execute_request(conn, {:foreign_assignments, base, project, profile, root, ids}) do
    sql = """
    SELECT issue_id FROM assignment_owners
    WHERE tracker_base_url = ?1 AND project_key = ?2 AND (profile_id != ?3 OR workspace_root != ?4)
      AND issue_id IN (SELECT value FROM json_each(?5))
    """

    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, [base, project, profile, root, ids]) do
          collect_issue_ids(conn, statement, [])
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp collect_issue_ids(conn, statement, acc) do
    case Sqlite3.step(conn, statement) do
      {:row, [id]} -> collect_issue_ids(conn, statement, [id | acc])
      :done -> {:ok, MapSet.new(acc)}
      {:error, _reason} -> {:error, :assignment_database_unavailable}
    end
  end

  defp step(conn, sql, args) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, args), do: Sqlite3.step(conn, statement)
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp identity(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, inode: inode, major_device: device}} -> {device, inode}
      _ -> nil
    end
  end

  defp call(server, request) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> {:error, :assignment_database_unavailable}
  end
end
