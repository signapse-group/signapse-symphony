defmodule SymphonyElixirWeb.ProfileObservability do
  @moduledoc false

  alias SymphonyElixir.{HostResources, Instructions, Profile, RuntimeControl, WorkflowStore}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @control_keys ~w(enabled mode desired_state changed_at version active_turns quota_checked_at)a
  @session_inspection "Session cleanup requires inspection"
  @checkout_messages %{
    "checkout_workflow_missing" => "Workflow missing from checkout",
    "checkout_workflow_invalid" => "Workflow must be valid prompt-only Markdown",
    "checkout_agents_missing" => "AGENTS.md missing from checkout",
    "checkout_agents_invalid" => "Invalid AGENTS.md in checkout",
    "checkout_skills_missing" => "Required skill missing from checkout",
    "checkout_skills_invalid" => "Invalid skill in checkout",
    "checkout_required_file_missing" => "Required instruction file missing from checkout",
    "checkout_required_file_invalid" => "Invalid required instruction file in checkout",
    "checkout_head_unavailable" => "Git revision unavailable in checkout",
    "checkout_instructions_invalid" => "Checkout instruction check failed",
    "checkout_prompt_invalid" => "Checkout prompt could not be rendered"
  }
  @retry_messages %{
    "session_heartbeat_expired" => "Session heartbeat expired",
    "host_pressure_stall" => "Worker stalled during host resource pressure",
    "stalled" => "Worker stalled without Codex activity",
    "provider_quota_exhausted" => "Codex provider quota exhausted",
    "provider_quota_unavailable" => "Could not read Codex provider quota",
    "resource_busy" => "Waiting for shared browser resources"
  }

  @spec mode() :: :profiles | :legacy
  def mode, do: Endpoint.config(:observability_mode, :legacy)

  @spec known?(String.t()) :: boolean()
  def known?(id), do: mode() == :profiles and match?({:ok, _profile}, Profile.lookup(id))

  @spec label(String.t()) :: String.t()
  def label(id) when id in ["fe", "be", "qa"], do: String.upcase(id)
  def label(id), do: String.capitalize(id)

  @spec overview() :: map()
  def overview do
    profiles = read_profiles(Profile.ids(), &read_summary/1)

    health =
      case Enum.count(profiles, &(&1.health == "healthy")) do
        0 -> "unavailable"
        count when count == length(profiles) -> "healthy"
        _ -> "partial"
      end

    %{mode: "profiles", health: health, profiles: profiles}
  end

  @spec summary(String.t()) :: map()
  def summary(id), do: hd(read_profiles([id], &read_summary/1))

  defp read_summary(id), do: summary(id, scheduler_call(id, :snapshot))

  @spec state(String.t()) :: map()
  def state(id), do: hd(read_profiles([id], &read_state/1))

  defp read_state(id) do
    snapshot = scheduler_call(id, :snapshot)
    generated_at = generated_at()
    summary = summary(id, snapshot)

    payload =
      case snapshot do
        %{} -> snapshot |> sanitize_snapshot() |> Presenter.project_state(generated_at)
        error -> %{generated_at: generated_at, error: snapshot_error(error)}
      end

    Map.merge(payload, summary)
  end

  defp read_profiles(ids, read) do
    SymphonyElixirWeb.ProfileTasks
    |> Task.Supervisor.async_stream_nolink(ids, &safe_read_profile(&1, read),
      max_concurrency: 5,
      timeout: 3 * snapshot_timeout(),
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, {id, reason}} -> unavailable_profile(id, reason)
    end)
  catch
    :exit, _reason -> Enum.map(ids, &unavailable_profile(&1, :unavailable))
  end

  defp safe_read_profile(id, read) do
    read.(id)
  rescue
    _error -> unavailable_profile(id, :unavailable)
  catch
    :exit, {:timeout, _} -> unavailable_profile(id, :timeout)
    _kind, _reason -> unavailable_profile(id, :unavailable)
  end

  defp unavailable_profile(id, reason) do
    error = snapshot_error(reason)

    %{
      profile_id: id,
      health: "unavailable",
      reason: error.code,
      error: error,
      workflow_revision: nil,
      instructions_source: instructions_source(id),
      instructions_revision: nil,
      max_concurrent_agents: nil,
      generated_at: generated_at(),
      runtime_control: public_control(id, %{database_error: true})
    }
  end

  defp generated_at, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @spec issue(String.t(), String.t()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue(id, identifier) do
    case scheduler_call(id, :snapshot) do
      %{} = snapshot ->
        workspace_root = fn -> workspace_root(id) end

        with {:ok, issue} <- snapshot |> sanitize_snapshot() |> Presenter.project_issue(identifier, workspace_root) do
          {:ok, Map.put(issue, :profile_id, id)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh(String.t()) :: {:ok, map()} | {:error, :unavailable}
  def refresh(id) do
    case scheduler_call(id, :request_refresh) do
      %{requested_at: %DateTime{} = requested_at} = payload ->
        {:ok, %{queued: payload.queued, coalesced: payload.coalesced, requested_at: DateTime.to_iso8601(requested_at), operations: payload.operations, profile_id: id}}

      _ ->
        {:error, :unavailable}
    end
  end

  @spec perform(String.t(), :pause | :resume | :activate, term()) :: String.t()
  def perform(id, :pause, _revision) do
    case RuntimeControl.pause("Paused by operator from the dashboard", "manual", control_server(id)) do
      {:ok, _status} -> "Pause requested."
      {:error, _reason} -> "Could not pause this profile."
    end
  end

  def perform(id, :resume, _revision) do
    case summary(id) do
      %{health: "healthy"} ->
        case RuntimeControl.resume(control_server(id)) do
          {:ok, _status} -> "Resume requested. Checking quota."
          {:error, _reason} -> "Could not resume this profile."
        end

      _ ->
        "This profile must be healthy before it can resume."
    end
  end

  def perform(id, :activate, revision) when is_binary(revision) and byte_size(revision) <= 128 do
    case instructions_source(id) do
      "checkout" ->
        "This profile reads instructions from the task checkout."

      _ ->
        case instruction_call(:activate, [id, revision]) do
          {:ok, _pin} -> "Workflow revision activated."
          {:error, reason} -> "Workflow activation failed (#{safe_code(reason, "invalid_instructions")})."
        end
    end
  end

  def perform(_id, :activate, _revision), do: "Enter a staged instructions revision."

  @spec issue_path(String.t() | nil, String.t()) :: String.t()
  def issue_path(nil, identifier), do: "/api/v1/#{URI.encode(identifier, &URI.char_unreserved?/1)}"

  def issue_path(id, identifier) do
    "/api/v1/profiles/#{id}/issues/#{URI.encode(identifier, &URI.char_unreserved?/1)}"
  end

  defp workspace_root(id) do
    case WorkflowStore.snapshot(id) do
      {:ok, config} -> config.settings.workspace.root
      {:error, _reason} -> nil
    end
  end

  defp summary(id, snapshot) do
    config = workflow_status(id)
    control = control_status(id, snapshot)
    reason = unavailable_reason(config, snapshot, control)
    source = instructions_source(id)

    %{
      profile_id: id,
      health: if(reason, do: "unavailable", else: "healthy"),
      reason: reason,
      browser_lock: browser_lock(id),
      admission_error: admission_error(snapshot),
      workflow_revision: config.revision,
      workflow_reload_error: config.reload_error,
      instructions_source: source,
      instructions_revision: if(source == "package", do: instructions_revision(id, snapshot)),
      max_concurrent_agents: max_concurrent_agents(id, snapshot),
      runtime_control: control
    }
  end

  defp instructions_source(id) do
    case Profile.lookup(id) do
      {:ok, %{checkout_workflow: path}} when is_binary(path) -> "checkout"
      {:ok, _profile} -> "package"
      {:error, _reason} -> nil
    end
  end

  defp browser_lock(id) when id in ["fe", "qa"] do
    case HostResources.snapshot(nil) do
      {:ok, %{browser_lock: lock}} when lock in [:locked, :unlocked] -> Atom.to_string(lock)
      _ -> nil
    end
  end

  defp browser_lock(_id), do: nil

  defp admission_error(%{admission_error: reason}) when reason in [:provider_quota_exhausted, :provider_quota_unavailable], do: Atom.to_string(reason)
  defp admission_error(_snapshot), do: nil

  defp workflow_status(id) do
    case WorkflowStore.status(id) do
      {:ok, status} ->
        %{status | error: safe_code(status.error, "workflow_unavailable"), reload_error: safe_code(status.reload_error, "workflow_reload_failed")}

      {:error, reason} ->
        %{revision: nil, error: safe_code(reason, "workflow_unavailable"), reload_error: nil}
    end
  end

  defp unavailable_reason(%{error: error}, _snapshot, _control) when not is_nil(error), do: error
  defp unavailable_reason(_config, :timeout, _control), do: "snapshot_timeout"
  defp unavailable_reason(_config, :unavailable, _control), do: "snapshot_unavailable"

  defp unavailable_reason(_config, %{readiness: %{ready: false, error: error}}, _control) do
    safe_code(error, "profile_not_ready") || "profile_not_ready"
  end

  defp unavailable_reason(_config, %{readiness: %{ready: true}}, %{enabled: true, database_error: nil}), do: nil
  defp unavailable_reason(_config, _snapshot, %{database_error: error}) when not is_nil(error), do: error
  defp unavailable_reason(_config, _snapshot, _control), do: "profile_not_ready"

  defp max_concurrent_agents(_id, %{max_concurrent_agents: cap}) when is_integer(cap), do: cap

  defp max_concurrent_agents(id, _snapshot) do
    case WorkflowStore.snapshot(id) do
      {:ok, config} -> config.settings.agent.max_concurrent_agents
      {:error, _reason} -> nil
    end
  end

  defp instructions_revision(id, snapshot) do
    case instruction_call(:status, [id]) do
      {:ok, %{revision: revision}} -> revision
      _ -> if is_map(snapshot), do: snapshot[:instructions_revision]
    end
  end

  defp instruction_call(function, args) do
    module = Endpoint.config(:instructions, Instructions)

    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      {:error, :instructions_unavailable}
    end
  end

  defp control_status(id, %{runtime_control: %{} = control}), do: public_control(id, control)

  defp control_status(id, _snapshot) do
    case GenServer.call(control_server(id), :status, snapshot_timeout()) do
      {:ok, %{} = control} -> public_control(id, control)
      {:error, _reason} -> public_control(id, %{database_error: true})
    end
  catch
    :exit, _reason -> public_control(id, %{database_error: true})
  end

  defp public_control(id, control) do
    mode = Map.get(control, :mode, :unknown)
    health = get_in(control, [:services, id, :status])

    control
    |> Map.take(@control_keys)
    |> Map.merge(%{
      enabled: Map.get(control, :enabled, true),
      mode: mode,
      desired_state: Map.get(control, :desired_state, desired_state(mode)),
      source: safe_source(Map.get(control, :source)),
      reason: public_control_reason(mode, control[:source]),
      services: if(health, do: %{id => %{status: health}}, else: %{}),
      database_error: if(control[:database_error], do: "runtime_control_unavailable"),
      quota_summary: if(control[:quota_summary], do: "Quota check completed"),
      active_turns: Map.get(control, :active_turns, 0)
    })
  end

  defp desired_state(:running), do: "running"
  defp desired_state(mode) when mode in [:pausing, :paused, :checking_quota], do: "paused"
  defp desired_state(_mode), do: "unknown"

  defp safe_source(source) when source in ["manual", "quota", "quota_check", "resume", "infrastructure", "checkout_instructions"], do: source
  defp safe_source(_source), do: nil

  defp public_control_reason(:checking_quota, _source), do: "Checking Codex quota"
  defp public_control_reason(mode, "checkout_instructions") when mode in [:paused, :pausing], do: "Fix the checkout instructions before resuming"
  defp public_control_reason(mode, "infrastructure") when mode in [:paused, :pausing], do: "Infrastructure retry limit reached"
  defp public_control_reason(:pausing, _source), do: "Waiting for active workers to finish"
  defp public_control_reason(_mode, _source), do: nil

  defp scheduler_call(id, request) do
    # The scoped servers use Registry names. Bound this read so a slow profile cannot stall the dashboard.
    GenServer.call(Profile.via(id, :orchestrator), request, snapshot_timeout())
  catch
    :exit, {:timeout, _reason} -> :timeout
    :exit, _reason -> :unavailable
  end

  defp control_server(id), do: Profile.via(id, :runtime_control)
  defp snapshot_timeout, do: Endpoint.config(:snapshot_timeout_ms, 500)

  defp safe_code(nil, _fallback), do: nil
  defp safe_code(reason, _fallback) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_code(_reason, fallback), do: fallback

  defp snapshot_error(:timeout), do: %{code: "snapshot_timeout", message: "Snapshot timed out"}
  defp snapshot_error(_error), do: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}

  defp sanitize_snapshot(snapshot) do
    {held, running} = snapshot.running |> Enum.map(&sanitize_entry/1) |> Enum.split_with(& &1[:handoff_error])
    blocked = Enum.map(Map.get(snapshot, :blocked, []), &sanitize_entry/1)
    held = Enum.map(held, &Map.merge(&1, %{error: @session_inspection, blocked_at: nil}))

    snapshot
    |> Map.put(:running, running)
    |> Map.update!(:retrying, &Enum.map(&1, fn entry -> sanitize_entry(entry) end))
    |> Map.put(:blocked, blocked ++ held)
    |> Map.put(:rate_limits, nil)
    |> Map.delete(:runtime_control)
  end

  defp sanitize_entry(entry) do
    code = entry[:reason_code]
    checkout_message = @checkout_messages[code]
    message = checkout_message || @retry_messages[code]

    entry
    |> Map.update(:handoff_error, nil, fn reason -> if reason, do: @session_inspection end)
    |> Map.update(:error, message, fn reason -> message || if(reason, do: "See service logs for details") end)
    |> Map.put(:reason_code, if(message, do: code))
    |> Map.put(:last_codex_message, nil)
    |> Map.put(:checkout_failure_path, if(checkout_message, do: safe_relative_path(entry[:checkout_failure_path])))
    |> Map.put(:checkout_head, safe_digest(entry[:checkout_head], [40, 64]))
    |> Map.put(:checkout_prompt_digest, safe_digest(entry[:checkout_prompt_digest], [64]))
  end

  defp safe_relative_path(path) when is_binary(path) and byte_size(path) <= 256 do
    segments = String.split(path, "/")

    if Enum.all?(segments, &(&1 not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, &1))), do: path
  end

  defp safe_relative_path(_path), do: nil

  defp safe_digest(value, lengths) when is_binary(value) do
    if byte_size(value) in lengths and Regex.match?(~r/\A[0-9a-f]+\z/, value), do: value
  end

  defp safe_digest(_value, _lengths), do: nil
end
