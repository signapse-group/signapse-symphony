defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when `WORKFLOW.md` changes.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Profile}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Profile.Reservations
  alias SymphonyElixir.Workflow

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    @derive {Inspect, except: [:workflow, :settings]}
    defstruct [:path, :stamp, :workflow, :settings, :profile, :table, :reload_error]
  end

  defmodule Snapshot do
    @moduledoc "Validated configuration captured for a profile operation."

    @derive {Inspect, except: [:env, :workflow, :settings]}
    @enforce_keys [:profile_id, :workflow_path, :instructions_root, :workflow, :settings, :revision, :env]
    defstruct [
      :profile_id,
      :workflow_path,
      :instructions_root,
      :checkout_workflow,
      :workflow,
      :settings,
      :revision,
      :env,
      :instructions,
      :workspace_prepared,
      :hook_started,
      :hook_stopped,
      require_contained_hook: false
    ]

    @type t :: %__MODULE__{
            profile_id: String.t(),
            workflow_path: Path.t(),
            instructions_root: Path.t() | nil,
            checkout_workflow: Path.t() | nil,
            workflow: Workflow.loaded_workflow(),
            settings: Schema.t(),
            revision: String.t(),
            env: %{String.t() => String.t()},
            instructions: SymphonyElixir.Instructions.pin() | nil,
            workspace_prepared: (Path.t() -> term()) | nil,
            hook_started: (map() -> term()) | nil,
            hook_stopped: (-> term()) | nil,
            require_contained_hook: boolean()
          }
  end

  @type status :: %{revision: String.t() | nil, error: term(), reload_error: term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :profile) do
      {:ok, profile} ->
        GenServer.start_link(__MODULE__, opts, name: Profile.via(profile.id, :workflow_store))

      :error ->
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @spec snapshot(String.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def snapshot(id) do
    with {:ok, state} <- profile_state(id) do
      case state do
        %State{workflow: nil, reload_error: error} ->
          {:error, error}

        %State{} ->
          {:ok,
           %Snapshot{
             profile_id: id,
             workflow_path: state.path,
             instructions_root: state.profile.instructions_root,
             checkout_workflow: state.profile.checkout_workflow,
             workflow: state.workflow,
             settings: state.settings,
             revision: state.stamp,
             env: state.profile.env
           }}
      end
    end
  end

  @spec status(String.t()) :: {:ok, status()} | {:error, term()}
  def status(id) do
    with {:ok, state} <- profile_state(id) do
      case state do
        %State{workflow: nil, reload_error: error} ->
          {:ok, %{revision: nil, error: error, reload_error: nil}}

        %State{stamp: revision, reload_error: error} ->
          {:ok, %{revision: revision, error: nil, reload_error: error}}
      end
    end
  end

  @spec force_reload(String.t()) :: :ok | {:error, term()}
  def force_reload(id) do
    with {:ok, _state} <- profile_state(id) do
      GenServer.call(Profile.via(id, :workflow_store), :force_reload)
    end
  catch
    :exit, _reason -> {:error, :profile_store_unavailable}
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case cached_state() do
      %State{workflow: workflow} ->
        {:ok, workflow}

      nil ->
        Workflow.load()
    end
  end

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case cached_state() do
      %State{settings: settings} ->
        {:ok, settings}

      nil ->
        case load_state(Workflow.workflow_file_path()) do
          {:ok, %State{settings: settings}} -> {:ok, settings}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :force_reload)

      _ ->
        case load_state(Workflow.workflow_file_path()) do
          {:ok, _state} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def init(profile: %Profile{} = profile) do
    table = :ets.new(__MODULE__, [:protected, read_concurrency: true])
    Profile.register_workflow_cache(profile.id, table)
    state = %State{path: profile.workflow_path, profile: profile, table: table}
    {_result, state} = refresh(state)
    schedule_poll()
    {:ok, state}
  end

  def init(_opts) do
    case load_state(Workflow.workflow_file_path()) do
      {:ok, state} ->
        :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
        cache_state(state)
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:force_reload, _from, %State{profile: %Profile{}} = state) do
    {result, state} = refresh(state)
    {:reply, result, state}
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        cache_state(new_state)
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_info(:poll, %State{profile: %Profile{}} = state) do
    {_result, state} = refresh(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} ->
        cache_state(new_state)
        {:noreply, new_state}

      {:error, _reason, new_state} ->
        {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp profile_state(id) do
    with {:ok, _profile} <- Profile.lookup(id) do
      case cached_state(Profile.workflow_cache(id)) do
        nil -> {:error, :profile_store_unavailable}
        state -> {:ok, state}
      end
    end
  end

  defp cached_state(table \\ __MODULE__)
  defp cached_state(nil), do: nil

  defp cached_state(table) do
    case :ets.lookup(table, :state) do
      [{:state, state}] -> state
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp cache_state(state) do
    :ets.insert(state.table || __MODULE__, {:state, state})
    :ok
  end

  defp refresh(%State{} = state) do
    case load_profile(state) do
      {:ok, loaded} ->
        new_state = %{loaded | reload_error: nil}
        cache_state(new_state)
        {:ok, new_state}

      {:error, reason} ->
        if reason != state.reload_error do
          Logger.warning("Profile workflow unavailable profile=#{state.profile.id} reason=#{inspect(reason)}")
        end

        new_state = %{state | reload_error: reason}
        cache_state(new_state)
        {{:error, reason}, new_state}
    end
  end

  defp load_profile(%State{profile: %Profile{error: reason}}) when not is_nil(reason), do: {:error, reason}

  defp load_profile(%State{profile: profile, path: path} = state) do
    case read_workflow(path) do
      {:ok, content} ->
        stamp = revision(content)

        if state.stamp == stamp do
          {:ok, state}
        else
          validate_profile_content(state, profile, content, stamp)
        end

      {:error, reason} ->
        {:error, safe_profile_error(reason)}
    end
  end

  defp validate_profile_content(state, profile, content, stamp) do
    with {:ok, workflow} <- parse_profile_workflow(content),
         {:ok, settings} <- Schema.parse(workflow.config, profile.env),
         :ok <- Config.validate_settings(settings),
         settings = expand_workspace(settings, state.path),
         {:ok, ownership} <- Profile.ownership(profile, settings),
         :ok <- Reservations.reserve(profile.id, ownership) do
      settings = put_in(settings.workspace.root, ownership.workspace)
      settings = put_in(settings.runtime_control.path, ownership.control)

      {:ok, %{state | stamp: stamp, workflow: workflow, settings: settings}}
    else
      {:error, reason} -> {:error, safe_profile_error(reason)}
    end
  rescue
    Protocol.UndefinedError -> {:error, :invalid_workflow_config}
  end

  defp parse_profile_workflow(content) do
    if String.valid?(content), do: Workflow.parse(content), else: {:error, :invalid_workflow_encoding}
  end

  defp expand_workspace(%{workspace: %{root: root}} = settings, path) when is_binary(root) do
    put_in(settings.workspace.root, Path.expand(root, Path.dirname(path)))
  end

  defp expand_workspace(settings, _path), do: settings

  defp safe_profile_error(reason) when is_atom(reason), do: reason
  defp safe_profile_error({reason, _detail}) when is_atom(reason), do: reason
  defp safe_profile_error({reason, _path, _detail}) when is_atom(reason), do: reason

  defp reload_state(%State{} = state) do
    path = Workflow.workflow_file_path()

    case load_state(path, state) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp load_state(path, state \\ nil) do
    with {:ok, content} <- read_workflow(path),
         {:ok, stat} <- File.stat(path, time: :posix) do
      stamp = {stat.mtime, stat.size, revision(content)}

      case state do
        %State{path: ^path, stamp: ^stamp} ->
          {:ok, state}

        _ ->
          parse_legacy_workflow(content, path, stamp)
      end
    end
  end

  defp parse_legacy_workflow(content, path, stamp) do
    with {:ok, workflow} <- Workflow.parse(content),
         {:ok, settings} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(settings) do
      {:ok, %State{path: path, stamp: stamp, workflow: workflow, settings: settings}}
    end
  end

  defp read_workflow(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp revision(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end
end
