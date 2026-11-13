defmodule SymphonyElixir.Profile do
  @moduledoc """
  Loads the deployment manifest and supervises the grouped configuration stores.
  """

  use Supervisor

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Jira.Client
  alias SymphonyElixir.{PathSafety, WorkflowStore}

  @routes %{
    "fe" => "route-frontend",
    "be" => "route-backend",
    "qa" => "route-quality-assurance",
    "landing" => "route-landing"
  }
  @ids ~w(fe be qa landing planning)
  @registry SymphonyElixir.ProfileRegistry
  @env_name ~r/^[a-zA-Z_][a-zA-Z_0-9]*$/

  @derive {Inspect, except: [:env]}
  @enforce_keys [:id]
  defstruct [:id, :workflow_path, :instructions_root, :control_path, :error, env: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          workflow_path: Path.t() | nil,
          instructions_root: Path.t() | nil,
          control_path: Path.t() | nil,
          error: term(),
          env: %{String.t() => String.t()}
        }

  @spec load(Path.t(), map()) :: {:ok, [t()]} | {:error, term()}
  def load(path, host_env \\ System.get_env()) do
    with {:ok, {_manifest, profiles}} <- load_manifest(path, host_env), do: {:ok, profiles}
  end

  @spec load_runtime(Path.t(), map()) :: {:ok, {[t()], Path.t()}} | {:error, term()}
  def load_runtime(path, host_env \\ System.get_env()) do
    with {:ok, {manifest, profiles}} <- load_manifest(path, host_env),
         {:ok, owners_path} <- manifest_control_path(manifest["assignment_owners_path"], host_env),
         :ok <- separate_owners_path(owners_path, profiles) do
      {:ok, {profiles, owners_path}}
    else
      {:error, :invalid_profile_control_path} -> {:error, :invalid_assignment_owners_path}
      {:error, _reason} = error -> error
    end
  end

  defp load_manifest(path, host_env) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"profiles" => [_ | _] = entries} = manifest} <- Jason.decode(contents),
         {:ok, profiles} <- parse_entries(entries, Path.dirname(Path.expand(path)), host_env) do
      {:ok, {manifest, profiles}}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_profiles_json}
      {:ok, _} -> {:error, :invalid_profiles_manifest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp separate_owners_path(owners_path, profiles) do
    if Enum.any?(profiles, &overlaps_owners_path?(&1, owners_path)), do: {:error, :overlapping_assignment_owners_path}, else: :ok
  end

  defp overlaps_owners_path?(profile, owners_path) do
    [profile.control_path, profile.instructions_root, profile.workflow_path]
    |> Enum.any?(&(is_binary(&1) and paths_overlap?(&1, owners_path)))
  end

  @spec start_link([t()] | {[t()], Path.t()}) :: Supervisor.on_start()
  def start_link(profiles), do: Supervisor.start_link(__MODULE__, profiles)

  @impl true
  def init({profiles, owners_path}) do
    runtime = Enum.map(profiles, &{SymphonyElixir.AgentRuntimeSupervisor, profile_id: &1.id})

    init_supervisor(
      profiles,
      [
        {SymphonyElixir.AssignmentOwners, path: owners_path},
        supervisor_child(:profile_runtimes, runtime)
      ],
      owners_path
    )
  end

  def init(profiles), do: init_supervisor(profiles, [], nil)

  defp init_supervisor(profiles, runtime_children, owners_path) do
    profiles = reserve_control_paths(profiles)
    catalog = Map.new(profiles, &{&1.id, &1})
    control_paths = for %{id: id, control_path: path} <- profiles, is_binary(path), into: %{}, do: {id, path}

    children =
      [
        {Registry, keys: :unique, name: @registry, meta: [profiles: catalog]},
        {SymphonyElixir.Profile.Reservations, Map.put(control_paths, :assignment_owners, owners_path)},
        supervisor_child(:profile_workflow_stores, Enum.map(profiles, &workflow_child/1))
      ] ++ runtime_children

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp supervisor_child(id, children), do: %{id: id, start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}, type: :supervisor}

  defp workflow_child(profile), do: Supervisor.child_spec({WorkflowStore, profile: profile}, id: {:workflow_store, profile.id})

  @spec ids() :: [String.t()]
  def ids do
    catalog = catalog()
    Enum.filter(@ids, &Map.has_key?(catalog, &1))
  end

  @spec lookup(String.t()) :: {:ok, t()} | {:error, :unknown_profile}
  def lookup(id) do
    case Map.fetch(catalog(), id) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, :unknown_profile}
    end
  end

  @spec via(String.t(), atom()) :: {:via, Registry, {module(), {String.t(), atom()}}}
  def via(id, role), do: {:via, Registry, {@registry, {id, role}}}

  @doc false
  @spec register_workflow_cache(String.t(), :ets.tid()) :: :ok
  def register_workflow_cache(id, table) do
    Registry.update_value(@registry, {id, :workflow_store}, fn _ -> table end)
    :ok
  end

  @doc false
  @spec workflow_cache(String.t()) :: :ets.tid() | nil
  def workflow_cache(id) do
    case Registry.lookup(@registry, {id, :workflow_store}) do
      [{_pid, table}] -> table
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec subprocess_env(%{required(:env) => %{String.t() => String.t()}, optional(atom()) => term()}, [String.t()]) ::
          [{String.t(), String.t() | nil}]
  def subprocess_env(%{env: env}, unset \\ []) do
    allowed = Map.drop(env, unset)

    System.get_env()
    |> Map.drop(Map.keys(allowed))
    |> Map.new(fn {key, _value} -> {key, nil} end)
    |> Map.merge(allowed)
    |> Map.merge(Map.new(unset, &{&1, nil}))
    |> Map.to_list()
  end

  @doc false
  @spec ownership(t(), Schema.t()) :: {:ok, map()} | {:error, term()}
  def ownership(profile, %{tracker: %{kind: "jira"} = tracker} = settings) do
    with {:ok, assignment} <- Client.assignment_scope(tracker),
         {:ok, states} <- assignment_states(tracker),
         :ok <- validate_assignment(profile.id, assignment, states, tracker.required_labels),
         {:ok, workspace} <- workspace_path(settings.workspace.root),
         instructions = profile.instructions_root,
         {:ok, control} <- control_path(profile, settings.runtime_control),
         :ok <- check_profile_paths(workspace, instructions, control) do
      {:ok,
       %{
         assignment: assignment,
         assignment_states: states,
         required_labels: Enum.sort(tracker.required_labels),
         workspace: workspace,
         instructions: instructions,
         control: control
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def ownership(_profile, _settings), do: {:error, :grouped_profiles_require_jira}

  @doc false
  @spec paths_overlap?(Path.t(), Path.t()) :: boolean()
  def paths_overlap?(left, right) do
    left_parts = comparable_path(left)
    right_parts = comparable_path(right)
    List.starts_with?(left_parts, right_parts) or List.starts_with?(right_parts, left_parts)
  end

  @doc false
  @spec collision(map(), map()) :: atom() | nil
  def collision(left, right) do
    path_collision(left, right) || assignment_collision(left.assignment, right.assignment)
  end

  defp path_collision(left, right) do
    cond do
      paths_overlap?(left.workspace, right.workspace) ->
        :overlapping_workspace_roots

      paths_overlap?(left.instructions, right.instructions) ->
        :overlapping_instructions_roots

      overlaps_profile_data?(left.workspace, right) or overlaps_profile_data?(right.workspace, left) ->
        :workspace_overlaps_profile_data

      true ->
        nil
    end
  end

  defp assignment_collision(left, right) do
    cond do
      Map.take(left, [:base_url, :project_key]) != Map.take(right, [:base_url, :project_key]) ->
        :different_jira_assignment_authority

      route_collision?(left, right) ->
        :overlapping_assignment_filters

      true ->
        nil
    end
  end

  defp overlaps_profile_data?(workspace, profile) do
    paths_overlap?(workspace, profile.instructions) or paths_overlap?(workspace, profile.control)
  end

  defp check_profile_paths(workspace, instructions, control) do
    cond do
      overlaps_profile_data?(workspace, %{instructions: instructions, control: control}) ->
        {:error, :workspace_overlaps_profile_data}

      paths_overlap?(instructions, control) ->
        {:error, :control_overlaps_instructions}

      true ->
        :ok
    end
  end

  defp catalog do
    case Registry.meta(@registry, :profiles) do
      {:ok, catalog} -> catalog
      :error -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  defp parse_entries(entries, directory, host_env) do
    ids =
      Enum.map(entries, fn
        %{"id" => id} -> id
        _ -> nil
      end)

    if Enum.uniq(ids) == ids and Enum.all?(ids, &(&1 in @ids)) do
      {:ok, Enum.map(entries, &parse_entry(&1, directory, host_env))}
    else
      {:error, :invalid_or_duplicate_profile_id}
    end
  end

  defp parse_entry(%{"id" => id} = entry, directory, host_env) do
    profile = %__MODULE__{id: id}

    case manifest_control_path(entry["control_path"], host_env) do
      {:ok, path} -> parse_workflow_entry(%{profile | control_path: path}, entry, directory, host_env)
      {:error, reason} -> %{profile | error: reason}
    end
  end

  defp parse_workflow_entry(profile, entry, directory, host_env) do
    with %{"workflow" => workflow, "instructions_root" => instructions, "env" => env} <- entry,
         true <- valid_path?(workflow) and valid_path?(instructions),
         {:ok, instructions_root} <- PathSafety.canonicalize(Path.expand(instructions, directory)),
         {:ok, env} <- resolve_env(env, host_env) do
      %{profile | workflow_path: Path.expand(workflow, directory), instructions_root: instructions_root, env: env}
    else
      {:error, reason} when is_atom(reason) -> %{profile | error: reason}
      _ -> %{profile | error: :invalid_profile_entry}
    end
  end

  defp manifest_control_path(value, host_env) do
    with {:ok, path} <- resolve_env_value(value, host_env),
         true <- valid_path?(path) and Path.type(path) == :absolute,
         {:ok, canonical_path} <- PathSafety.canonicalize(path) do
      {:ok, canonical_path}
    else
      _ -> {:error, :invalid_profile_control_path}
    end
  end

  defp reserve_control_paths(profiles) do
    Enum.map(profiles, fn
      %{control_path: nil} = profile ->
        profile

      profile ->
        if Enum.any?(profiles, &(&1.id != profile.id and is_binary(&1.control_path) and paths_overlap?(&1.control_path, profile.control_path))) do
          %{profile | control_path: nil, error: :overlapping_control_paths}
        else
          profile
        end
    end)
  end

  defp valid_path?(path), do: is_binary(path) and String.trim(path) != "" and not String.contains?(path, [<<0>>, "\r", "\n"])

  defp resolve_env(env, host_env) when is_map(env) do
    Enum.reduce_while(env, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      with true <- valid_env_name?(name),
           {:ok, value} <- resolve_env_value(value, host_env) do
        {:cont, {:ok, Map.put(acc, name, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        false -> {:halt, {:error, :invalid_profile_environment}}
      end
    end)
  end

  defp resolve_env(_env, _host_env), do: {:error, :invalid_profile_environment}

  defp resolve_env_value("$" <> name = value, host_env) do
    if valid_env_name?(name) do
      case Map.fetch(host_env, name) do
        {:ok, resolved} -> literal_env_value(resolved)
        :error -> {:error, :missing_profile_environment_reference}
      end
    else
      literal_env_value(value)
    end
  end

  defp resolve_env_value(value, _host_env), do: literal_env_value(value)

  defp literal_env_value(value) when is_binary(value) do
    if String.contains?(value, <<0>>), do: {:error, :invalid_profile_environment}, else: {:ok, value}
  end

  defp literal_env_value(_value), do: {:error, :invalid_profile_environment}

  defp valid_env_name?(name), do: is_binary(name) and Regex.match?(@env_name, name)

  defp validate_assignment("planning", %{issue_types: ["story"], routing_labels: []}, %{dispatch_states: ["planned"], active_states: ["planned"]}, []), do: :ok

  defp validate_assignment("planning", _assignment, _states, _labels), do: {:error, :invalid_planning_assignment_filter}

  defp validate_assignment(id, %{issue_types: ["subtask"], worker_routes: [route]}, _states, _labels) do
    if @routes[id] == route, do: :ok, else: {:error, :invalid_profile_assignment_filter}
  end

  defp validate_assignment(_id, _assignment, _states, _labels), do: {:error, :invalid_profile_assignment_filter}

  defp workspace_path(path) when is_binary(path), do: PathSafety.canonicalize(path)
  defp workspace_path(_path), do: {:error, :missing_profile_workspace_root}

  defp assignment_states(tracker) do
    states = Map.take(tracker, [:active_states, :dispatch_states, :terminal_states])

    if Enum.all?(states, fn {_field, values} -> is_list(values) and Enum.all?(values, &valid_path?/1) end) do
      {:ok, Map.new(states, fn {field, values} -> {field, values |> Enum.map(&Schema.normalize_issue_state/1) |> Enum.uniq() |> Enum.sort()} end)}
    else
      {:error, :invalid_profile_assignment_states}
    end
  end

  defp control_path(%{id: id, control_path: expected}, %{enabled: true, id: id, members: [id], path: path}) do
    case PathSafety.canonicalize(path) do
      {:ok, ^expected} -> {:ok, expected}
      _ -> {:error, :invalid_profile_runtime_control}
    end
  end

  defp control_path(_profile, _control), do: {:error, :invalid_profile_runtime_control}

  defp route_collision?(%{issue_types: ["subtask"]} = left, %{issue_types: ["subtask"]} = right) do
    left.worker_routes == right.worker_routes or
      not Enum.all?(left.worker_routes, &(&1 in right.routing_labels)) or
      not Enum.all?(right.worker_routes, &(&1 in left.routing_labels))
  end

  defp route_collision?(_left, _right), do: false

  defp comparable_path(path) do
    path = if match?({:win32, _}, :os.type()), do: String.downcase(path), else: path
    Path.split(path)
  end
end

defmodule SymphonyElixir.Profile.Reservations do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.Profile

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(control_paths), do: GenServer.start_link(__MODULE__, control_paths, name: __MODULE__)

  @spec reserve(String.t(), map()) :: :ok | {:error, term()}
  def reserve(id, ownership), do: GenServer.call(__MODULE__, {:reserve, id, ownership})

  @impl true
  def init(control_paths), do: {:ok, %{control_paths: control_paths, ownership: %{}}}

  @impl true
  def handle_call({:reserve, id, ownership}, _from, state) do
    case Map.fetch(state.ownership, id) do
      {:ok, ^ownership} ->
        {:reply, :ok, state}

      {:ok, _ownership} ->
        {:reply, {:error, :ownership_change_requires_drained_restart}, state}

      :error ->
        case find_conflict(state, id, ownership) do
          nil -> {:reply, :ok, put_in(state.ownership[id], ownership)}
          conflict -> {:reply, {:error, conflict}, state}
        end
    end
  end

  defp find_conflict(state, id, ownership) do
    Enum.find_value(state.control_paths, fn {other_id, path} ->
      if id != other_id and is_binary(path) and overlaps_control_path?(ownership, path) do
        {:profile_overlaps_control_path, other_id}
      end
    end) ||
      Enum.find_value(state.ownership, fn {other_id, other} ->
        if reason = Profile.collision(ownership, other), do: {reason, other_id}
      end)
  end

  defp overlaps_control_path?(ownership, path) do
    Profile.paths_overlap?(ownership.workspace, path) or Profile.paths_overlap?(ownership.instructions, path)
  end
end
