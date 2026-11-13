defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.AssignmentOwners
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.HostResources
  alias SymphonyElixir.Instructions
  alias SymphonyElixir.Jira.Client, as: JiraClient
  alias SymphonyElixir.Profile
  alias SymphonyElixir.RuntimeControl
  alias SymphonyElixir.StatusDashboard
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkflowStore
  alias SymphonyElixir.WorkflowUpdate
  alias SymphonyElixir.Workspace
  alias SymphonyElixirWeb.ObservabilityPubSub

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @quota_retry_delay_ms 5_000
  @instructions_check_interval_ms 60_000
  @handoff_recovery "Phase boundary handoff requires operator confirmation"
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :profile_id,
      :profile_snapshot,
      :instructions_revision,
      :instructions_fingerprint,
      :instructions_check_at,
      :readiness_error,
      :config_error,
      :recovery_error,
      :assignment_scope,
      :quota_hold,
      instructions: Instructions,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      retry_restore_pending: true,
      tracker_tasks: %{},
      candidate_snapshot: nil,
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    case opts[:profile_id] do
      nil ->
        init_legacy(opts)

      id ->
        metadata = [profile_id: id]
        Logger.metadata(metadata)

        state = %State{
          profile_id: id,
          poll_interval_ms: 1_000,
          task_supervisor: Keyword.fetch!(opts, :task_supervisor),
          instructions: Keyword.get(opts, :instructions, Instructions),
          codex_totals: @empty_codex_totals,
          readiness_error: :starting
        }

        {:ok, schedule_tick(state, 0)}
    end
  end

  defp init_legacy(opts) do
    case Config.settings() do
      {:ok, config} ->
        now_ms = System.monotonic_time(:millisecond)

        state = %State{
          poll_interval_ms: config.polling.interval_ms,
          max_concurrent_agents: config.agent.max_concurrent_agents,
          next_poll_due_at_ms: now_ms,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: nil,
          task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
          codex_totals: @empty_codex_totals,
          codex_rate_limits: nil
        }

        state = restore_pending_retries(state)
        run_terminal_workspace_cleanup(state)
        state = schedule_tick(state, 0)

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard(state)
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard(state)
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, %{tracker_tasks: tasks} = state) do
    if Enum.any?(tasks, fn {_ref, task} -> match?({:poll, _, _}, task.purpose) or task.purpose == :profile_recovery end) do
      {:noreply, state}
    else
      start_poll(state)
    end
  end

  def handle_info({ref, result}, %{tracker_tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {task, tasks} = Map.pop(tasks, ref)
    apply_tracker_result(%{state | tracker_tasks: tasks}, task, result)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tracker_tasks: tasks} = state) when is_map_key(tasks, ref) do
    {task, tasks} = Map.pop(tasks, ref)
    apply_tracker_result(%{state | tracker_tasks: tasks}, task, {:error, {:tracker_task_failed, reason}})
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        cond do
          match?({:session_not_started, _}, reason) ->
            finish_stopped_worker(state, issue_id, reason)

          state.running[issue_id][:handoff_error] ->
            {:noreply, state}

          match?({:session_stop_unconfirmed, _}, reason) ->
            entry = state.running[issue_id]
            persist_retry(state, boundary_recovery(entry.issue, entry))
            {:noreply, hold_failed_handoff(state, entry.issue, entry, reason)}

          true ->
            finish_stopped_worker(state, issue_id, reason)
        end
    end
  end

  def handle_info({:worker_runtime_info, issue_id, info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      %{pid: pid} = running_entry when info.worker_pid == pid and not is_map_key(running_entry, :handoff_error) ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, info[:workspace_path])
          |> maybe_put_runtime_value(:session_process, info[:session_process])

        recovery = boundary_recovery(updated_running_entry.issue, updated_running_entry)
        persist_retry_state(state, Map.put(recovery, :error, interrupted_run_error(recovery)))

        notify_dashboard(state)
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      %{pid: pid} = running_entry when update.worker_pid == pid and not is_map_key(running_entry, :handoff_error) ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
        updated_running_entry = reset_successful_turn(state, updated_running_entry, update.event)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard(state)
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      if dispatch_ready?(state) do
        case pop_retry_attempt_state(state, issue_id, retry_token) do
          {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
          :missing -> {:noreply, state}
        end
      else
        {:noreply, defer_retry(state, issue_id, retry_token)}
      end

    notify_dashboard(state)
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp finish_stopped_worker(state, issue_id, reason) do
    entry = state.running[issue_id]

    stop_result = if match?({:session_not_started, _}, reason), do: :ok, else: stop_entry_session(entry)

    case stop_result do
      :ok ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{safe_error(reason)}")

        notify_dashboard(state)
        {:noreply, state}

      error ->
        persist_retry(state, boundary_recovery(entry.issue, entry))
        {:noreply, hold_failed_handoff(state, entry.issue, entry, error)}
    end
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      preserve_recovery = not is_nil(state.profile_id) or running_entry[:boundary_completed] == true

      state
      |> complete_issue(issue_id, preserve_recovery)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        delay_type: :continuation,
        error: if(running_entry[:boundary_completed], do: @handoff_recovery),
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, _session_id, {:quota_admission_deferred, reason})
       when reason in [:provider_quota_exhausted, :provider_quota_unavailable] do
    metadata = boundary_recovery(running_entry.issue, running_entry)
    metadata = if running_entry[:boundary_completed], do: metadata, else: %{metadata | error: nil}
    revision = running_entry.profile_snapshot.revision
    state = record_quota_hold(state, running_entry.issue, reason, revision)
    schedule_issue_retry(state, issue_id, max(metadata.attempt, 1), quota_retry_metadata(metadata, reason))
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    failure = if reason == :session_heartbeat_expired, do: "session_heartbeat_expired"
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{failure || "worker_exit"}; scheduling retry")

    error = if running_entry[:boundary_completed], do: @handoff_recovery, else: "agent exited: #{inspect(reason)}"
    schedule_worker_failure(state, running_entry, error, failure, HostResources.snapshot(running_entry[:worker_host]))
  end

  defp schedule_worker_failure(state, entry, error, reason_code, host_resources) do
    entry = current_retry_allowance(state, entry)
    count = Map.get(entry, :infrastructure_failures, 0)

    failures =
      case reason_code do
        reason when reason in ["session_heartbeat_expired", "host_pressure_stall"] -> count + 1
        "stalled" -> count
        _ -> 0
      end

    attempt = next_retry_attempt_from_running(entry) || 1
    pause_reason = if failures >= 3, do: "Infrastructure retry limit: #{entry.identifier} had #{failures} consecutive infrastructure failures"

    if reason_code do
      Logger.warning(
        "Worker retry classified #{issue_context(entry.issue)} session_id=#{running_entry_session_id(entry)} " <>
          "session_unit=#{inspect(get_in(entry, [:session_process, :containment, :unit]))} " <>
          "attempt=#{attempt} reason=#{reason_code} host_resources=#{inspect(host_resources)}"
      )
    end

    schedule_issue_retry(state, entry.issue.id, attempt, %{
      infrastructure_failures: if(pause_reason, do: 0, else: failures),
      retry_priority: entry[:retry_priority],
      retry_generation: entry[:retry_generation],
      identifier: entry.identifier,
      issue_url: entry.issue.url,
      worker_host: entry[:worker_host],
      workspace_path: entry[:workspace_path],
      reason_code: reason_code,
      error: error,
      pause_reason: pause_reason
    })
  end

  defp start_poll(state) do
    state = refresh_runtime_config(state)

    if state.profile_id && !state.profile_snapshot do
      finish_poll(%{state | candidate_snapshot: nil})
    else
      state |> refresh_instructions() |> run_poll()
    end
  end

  defp run_poll(%State{profile_id: id, retry_restore_pending: true} = state) when is_binary(id) do
    start_tracker_read(state, :profile_recovery, fn ->
      with :ok <- AssignmentOwners.ready(state.assignment_scope),
           {:ok, retries} <- RuntimeControl.pending_retries(control_id(state), control_server(state)),
           :ok <- reconcile_recovery(state, retries) do
        {:ok, retries}
      end
    end)
  end

  defp run_poll(state) do
    state = if state.profile_id, do: state, else: restore_pending_retries_if_needed(state)
    state = flush_retry_persistence(state)
    state = resume_deferred_retries(state)
    state = reconcile_stalled_running_issues(state)
    running = Map.new(state.running, fn {id, entry} -> {id, entry.pid} end)
    blocked = state.blocked
    dispatch_states = settings(state).tracker.dispatch_states
    snapshot = state.profile_snapshot

    start_tracker_read(%{state | poll_check_in_progress: true}, {:poll, running, blocked}, fn ->
      %{
        running: fetch_existing_issues(Map.keys(running), snapshot),
        blocked: fetch_existing_issues(Map.keys(blocked), snapshot),
        candidates: fetch_candidate_issues(dispatch_states, snapshot)
      }
    end)
  end

  defp fetch_existing_issues([], _snapshot), do: {:ok, []}
  defp fetch_existing_issues(ids, nil), do: Tracker.fetch_issues_by_ids(ids)
  defp fetch_existing_issues(ids, %{settings: %{tracker: tracker}}), do: Tracker.fetch_issues_by_ids(ids, tracker)

  defp fetch_candidate_issues(states, nil), do: with(:ok <- Config.validate!(), do: Tracker.fetch_issues_by_states(states))
  defp fetch_candidate_issues(states, %{settings: %{tracker: tracker}}), do: Tracker.fetch_issues_by_states(states, tracker)

  defp apply_tracker_result(state, task, result) do
    state = refresh_runtime_config(state)

    result =
      if task.tracker == tracker_revision(state) and is_nil(state.config_error),
        do: result,
        else: {:error, :tracker_config_changed}

    if current_tracker_read?(state, task.purpose),
      do: finish_tracker_read(state, task.purpose, result),
      else: {:noreply, state}
  end

  defp current_tracker_read?(state, {:dispatch, issue, attempt, _metadata}) when is_integer(attempt),
    do: current_retry_read?(state, issue.id)

  defp current_tracker_read?(state, {:retry, id, _attempt, _metadata}), do: current_retry_read?(state, id)
  defp current_tracker_read?(_state, _purpose), do: true

  defp current_retry_read?(state, id) do
    MapSet.member?(state.claimed, id) and not Map.has_key?(state.running, id) and
      not Map.has_key?(state.blocked, id) and not Map.has_key?(state.retry_attempts, id)
  end

  defp start_tracker_read(state, purpose, read) do
    entry = %{purpose: purpose, tracker: tracker_revision(state)}
    task = Task.Supervisor.async_nolink(state.task_supervisor, read)
    {:noreply, %{state | tracker_tasks: Map.put(state.tracker_tasks, task.ref, entry)}}
  end

  defp finish_tracker_read(state, {:poll, running, blocked}, %{candidates: candidates} = result) do
    current_running = Enum.filter(Map.keys(running), &(get_in(state.running, [&1, :pid]) == running[&1]))
    current_blocked = Enum.filter(Map.keys(blocked), &(state.blocked[&1] == blocked[&1]))
    state = apply_poll_reconciliation(state, current_running, result.running, :running)
    state = apply_poll_reconciliation(state, current_blocked, result.blocked, :blocked)
    state |> apply_candidate_read(candidates) |> finish_poll()
  end

  defp finish_tracker_read(state, {:poll, _, _}, error) do
    Logger.warning("Tracker poll failed: #{inspect(error)}")
    finish_poll(%{state | candidate_snapshot: nil})
  end

  defp finish_tracker_read(state, :profile_recovery, {:ok, retries}) do
    state = Enum.reduce(retries, state, &restore_one_retry/2)
    finish_poll(%{state | retry_restore_pending: false, recovery_error: nil})
  end

  defp finish_tracker_read(state, :profile_recovery, {:error, reason}) do
    Logger.warning("Profile recovery remains fenced reason=#{safe_error(reason)}")
    finish_poll(%{state | recovery_error: safe_error(reason)})
  end

  defp finish_tracker_read(state, {:dispatch, issue, attempt, metadata}, result) do
    state = update_candidate(state, issue.id, result)

    case result do
      {:quota_deferred, %Issue{} = refreshed, reason} ->
        state = record_quota_hold(state, refreshed, reason, tracker_revision(state))
        defer_admission(state, refreshed, attempt, quota_retry_metadata(metadata, reason))

      {:ok, %Issue{} = refreshed} ->
        finish_dispatch_admission(state, refreshed, attempt, metadata)

      {:skip, %Issue{} = refreshed} when is_integer(attempt) ->
        handle_retry_issue_lookup(refreshed, state, issue.id, attempt, metadata)

      {:skip, _} ->
        if is_nil(attempt), do: {:noreply, state}, else: {:noreply, release_issue_claim(state, issue.id)}

      {:error, reason} ->
        Logger.warning("Dispatch refresh failed #{issue_context(issue)} reason=#{inspect(reason)}")
        defer_admission(state, issue, attempt, metadata)
    end
  end

  defp finish_tracker_read(state, {:retry, issue_id, attempt, metadata}, result) do
    case result do
      {:ok, issues} ->
        issues |> find_issue_by_id(issue_id) |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        {:noreply, schedule_issue_retry(state, issue_id, attempt + 1, Map.put(metadata, :error, retry_error(metadata, "retry poll failed: #{inspect(reason)}")))}
    end
  end

  defp finish_dispatch_admission(state, issue, attempt, metadata) do
    case quota_hold_reason(state) do
      nil ->
        state = %{state | quota_hold: nil}

        if admission_ready?(state, issue, attempt, metadata) do
          {:noreply, do_dispatch_issue(state, issue, attempt, metadata[:worker_host], metadata)}
        else
          defer_admission(state, issue, attempt, metadata)
        end

      reason ->
        defer_admission(state, issue, attempt, quota_retry_metadata(metadata, reason))
    end
  end

  defp apply_candidate_read(state, {:ok, issues}) do
    {state, issues} = filter_assignment_conflicts(state, issues)

    state = %{
      state
      | candidate_snapshot: %{tracker: settings(state).tracker, issues: issues, updated_at: DateTime.utc_now()}
    }

    if dispatch_ready?(state), do: choose_issues(issues, state), else: state
  end

  defp apply_candidate_read(state, {:error, reason}) do
    Logger.warning("Tracker candidate read failed: #{inspect(reason)}")
    %{state | candidate_snapshot: nil}
  end

  defp filter_assignment_conflicts(%State{profile_id: nil} = state, issues), do: {state, issues}
  defp filter_assignment_conflicts(state, []), do: {state, []}

  defp filter_assignment_conflicts(state, issues) do
    owner = {state.profile_id, settings(state).workspace.root}

    case AssignmentOwners.foreign_assignments(state.assignment_scope, owner, Enum.map(issues, & &1.id)) do
      {:ok, foreign} ->
        {conflicts, eligible} = Enum.split_with(issues, &MapSet.member?(foreign, &1.id))
        {Enum.reduce(conflicts, state, &block_assignment_discrepancy(&2, &1, %{})), eligible}

      {:error, _reason} ->
        {state, []}
    end
  end

  defp update_candidate(%{candidate_snapshot: nil} = state, _id, _result), do: state

  defp update_candidate(state, id, {:quota_deferred, %Issue{} = refreshed, _reason}),
    do: update_candidate(state, id, {:ok, refreshed})

  defp update_candidate(state, id, {:ok, %Issue{} = refreshed}) do
    snapshot = state.candidate_snapshot
    issues = Enum.map(snapshot.issues, fn issue -> if issue.id == id, do: refreshed, else: issue end)
    %{state | candidate_snapshot: %{snapshot | issues: issues}}
  end

  defp update_candidate(state, id, _result), do: remove_candidate(state, id)

  defp remove_candidate(%{candidate_snapshot: nil} = state, _id), do: state

  defp remove_candidate(state, id) do
    snapshot = state.candidate_snapshot
    %{state | candidate_snapshot: %{snapshot | issues: Enum.reject(snapshot.issues, &(&1.id == id))}}
  end

  defp admission_ready?(state, issue, nil, _metadata),
    do: should_dispatch_issue?(issue, state, dispatch_state_set(state), terminal_state_set(state))

  defp admission_ready?(state, issue, _attempt, metadata) do
    current_retry_read?(state, issue.id) and
      candidate_issue?(issue, retry_allowed_states(state, metadata), terminal_state_set(state), state) and
      dispatch_slots_available?(issue, state) and retry_priority_available?(state, issue.id, metadata) and retry_worker_available?(state, metadata)
  end

  defp defer_admission(state, _issue, nil, _metadata), do: {:noreply, state}

  defp defer_admission(state, issue, attempt, metadata) do
    {:noreply, schedule_issue_retry(state, issue.id, attempt, metadata)}
  end

  defp record_quota_hold(%State{profile_snapshot: %{revision: revision}} = state, issue, reason, revision) do
    Logger.warning("Provider quota admission deferred #{issue_context(issue)} reason=#{reason}")
    state = %{state | quota_hold: {reason, System.monotonic_time(:millisecond) + @quota_retry_delay_ms}}
    notify_dashboard(state)
    state
  end

  defp record_quota_hold(state, _issue, _reason, _revision), do: state

  defp quota_hold_reason(%State{quota_hold: {reason, until_ms}}) do
    if System.monotonic_time(:millisecond) < until_ms, do: reason
  end

  defp quota_hold_reason(_state), do: nil

  defp quota_admission_error(%State{quota_hold: {reason, _until_ms}}), do: reason
  defp quota_admission_error(_state), do: nil

  defp quota_retry_metadata(metadata, reason) do
    reason_code = Atom.to_string(reason)
    Map.merge(metadata, %{error: retry_error(metadata, reason_code), reason_code: reason_code})
  end

  defp finish_poll(state) do
    state = schedule_tick(state, state.poll_interval_ms)
    notify_dashboard(state)
    {:noreply, %{state | poll_check_in_progress: false}}
  end

  defp apply_poll_reconciliation(state, ids, {:ok, issues}, kind) do
    issues = Enum.filter(issues, &(&1.id in ids))

    if kind == :running do
      issues
      |> reconcile_running_issue_states(state, active_state_set(state), terminal_state_set(state))
      |> reconcile_missing_running_issue_ids(ids, issues)
    else
      issues
      |> reconcile_blocked_issue_states(state, active_state_set(state), terminal_state_set(state))
      |> reconcile_missing_blocked_issue_ids(ids, issues)
    end
  end

  defp apply_poll_reconciliation(state, _ids, {:error, reason}, kind) do
    Logger.warning("Tracker reconciliation failed kind=#{kind} reason=#{inspect(reason)}")
    state
  end

  defp runtime_dispatch_enabled?(state) do
    case RuntimeControl.status(control_server(state)) do
      {:ok, %{mode: :running}} ->
        true

      {:ok, _status} ->
        false

      {:error, reason} ->
        Logger.debug("Runtime control unavailable; refusing new Codex work: #{inspect(reason)}")
        false
    end
  end

  defp dispatch_ready?(%State{retry_restore_pending: true}), do: false
  defp dispatch_ready?(%State{config_error: error}) when not is_nil(error), do: false
  defp dispatch_ready?(%State{readiness_error: error}) when not is_nil(error), do: false

  defp dispatch_ready?(%State{profile_id: id} = state) when is_binary(id),
    do: retry_persistence_ready?(state) and AssignmentOwners.ready(state.assignment_scope) == :ok and runtime_dispatch_enabled?(state)

  defp dispatch_ready?(state), do: retry_persistence_ready?(state) and runtime_dispatch_enabled?(state)

  defp retry_persistence_ready?(state), do: Enum.all?(state.retry_attempts, fn {_id, retry} -> not Map.has_key?(retry, :pending_write) end)

  defp control_server(%State{profile_id: nil}), do: RuntimeControl
  defp control_server(%State{profile_id: id}), do: Profile.via(id, :runtime_control)
  defp control_id(%State{profile_id: nil}), do: RuntimeControl.runtime_id()
  defp control_id(%State{profile_id: id}), do: id

  defp persist_retry(state, payload), do: RuntimeControl.persist_retry(control_id(state), payload, control_server(state))
  defp delete_retry(state, issue_id), do: RuntimeControl.delete_retry(control_id(state), issue_id, control_server(state))

  defp claim_assignment(%State{profile_id: nil}, _issue_id), do: :ok

  defp claim_assignment(state, issue_id) do
    AssignmentOwners.claim(assignment_key(state, issue_id), {state.profile_id, settings(state).workspace.root})
  end

  defp assignment_key(%State{assignment_scope: scope}, issue_id), do: {scope.base_url, scope.project_key, issue_id}

  defp owned_workspace?(%State{profile_id: nil}, _issue_id), do: true

  defp owned_workspace?(state, issue_id) do
    owner = {state.profile_id, settings(state).workspace.root}
    AssignmentOwners.owner(assignment_key(state, issue_id)) == {:ok, owner}
  end

  defp restore_pending_retries_if_needed(%State{retry_restore_pending: true} = state),
    do: restore_pending_retries(state)

  defp restore_pending_retries_if_needed(state), do: state

  defp defer_retry(%State{} = state, issue_id, retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{retry_token: ^retry_token} = retry ->
        deferred = %{
          retry
          | timer_ref: nil,
            retry_token: nil,
            due_at_ms: System.monotonic_time(:millisecond) + state.poll_interval_ms
        }

        %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, deferred)}

      _ ->
        state
    end
  end

  defp resume_deferred_retries(%State{} = state) do
    if dispatch_ready?(state) do
      state.retry_attempts
      |> Enum.filter(fn {_issue_id, retry} -> is_nil(retry.timer_ref) and is_nil(retry.retry_token) end)
      |> Enum.reduce(state, fn {issue_id, retry}, current_state ->
        schedule_issue_retry(current_state, issue_id, retry.attempt, %{
          identifier: retry.identifier,
          issue_url: retry.issue_url,
          error: retry.error,
          reason_code: retry[:reason_code],
          worker_host: retry.worker_host,
          workspace_path: retry.workspace_path,
          infrastructure_failures: Map.get(retry, :infrastructure_failures, 0),
          retry_generation: retry[:retry_generation],
          retry_priority: Map.get(retry, :retry_priority)
        })
      end)
    else
      state
    end
  end

  defp restore_pending_retries(%State{} = state) do
    case RuntimeControl.pending_retries(control_id(state), control_server(state)) do
      {:ok, retries} ->
        case reconcile_recovery(state, retries) do
          :ok ->
            retries
            |> Enum.reduce(state, &restore_one_retry/2)
            |> Map.put(:retry_restore_pending, false)
            |> Map.put(:recovery_error, nil)

          {:error, reason} ->
            Logger.error("Unable to reconcile recovery: #{inspect(reason)}; refusing dispatch")
            %{state | recovery_error: safe_error(reason)}
        end

      {:error, reason} ->
        Logger.error("Unable to restore pending issue retries: #{inspect(reason)}")
        %{state | retry_restore_pending: true, recovery_error: safe_error(reason)}
    end
  end

  defp restore_one_retry(%{"issue_id" => issue_id} = retry, state) when is_binary(issue_id) do
    state = %{state | claimed: MapSet.put(state.claimed, issue_id)}

    schedule_issue_retry(state, issue_id, max(retry["attempt"] || 0, 1), %{
      identifier: retry["identifier"],
      issue_url: restored_issue_url(retry, state),
      error: retry["error"],
      reason_code: retry["reason_code"],
      worker_host: retry["worker_host"],
      workspace_path: retry["workspace_path"],
      infrastructure_failures: retry["infrastructure_failures"] || 0,
      retry_generation: retry["retry_generation"] || 0,
      retry_priority: retry["retry_priority"]
    })
  end

  defp restore_one_retry(_retry, state), do: state

  defp reconcile_recovery(%State{profile_id: nil}, retries) do
    if Enum.any?(retries, &String.starts_with?(&1["error"] || "", @handoff_recovery)) do
      case RuntimeControl.pause(@handoff_recovery, "recovery") do
        {:ok, _} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  defp reconcile_recovery(state, retries) do
    Enum.reduce_while(retries, :ok, fn retry, :ok ->
      case reconcile_recovery_entry(state, retry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reconcile_recovery_entry(state, %{"issue_id" => id} = retry) when is_binary(id) do
    with :ok <- claim_assignment(state, id),
         :ok <- verify_recovered_workspace(state, retry) do
      stop_recovered_session(state, retry)
    end
  end

  defp reconcile_recovery_entry(_state, _retry), do: {:error, :invalid_retry_record}

  defp stop_recovered_session(_state, %{"worker_host" => host}) when is_binary(host),
    do: {:error, :profile_remote_workspace_unsupported}

  defp stop_recovered_session(state, %{"session_unit" => unit} = retry) when is_binary(unit) do
    case AppServer.stop_session(%{
           containment: %{unit: unit, invocation: retry["session_invocation"]},
           worker_host: retry["worker_host"],
           profile_snapshot: state.profile_snapshot,
           # A recorded invocation is required before the guard receives SYMPHONY_START.
           recovered: true
         }) do
      :ok -> :ok
      _ -> {:error, :recovered_session_stop_unconfirmed}
    end
  end

  defp stop_recovered_session(_state, _retry), do: :ok

  defp verify_recovered_workspace(state, %{"workspace_path" => path}) when is_binary(path) do
    root = settings(state).workspace.root

    case SymphonyElixir.PathSafety.canonicalize(path) do
      {:ok, canonical} ->
        if canonical != root and List.starts_with?(Path.split(canonical), Path.split(root)),
          do: :ok,
          else: {:error, :recovered_workspace_outside_profile}

      _ ->
        {:error, :recovered_workspace_outside_profile}
    end
  end

  defp verify_recovered_workspace(_state, _retry), do: :ok

  defp restored_issue_url(retry, %State{profile_id: nil}), do: Tracker.issue_url(retry["identifier"], retry["issue_url"])
  defp restored_issue_url(retry, state), do: Tracker.issue_url(retry["identifier"], retry["issue_url"], settings(state).tracker)

  defp persist_retry_state(state, recovery) do
    case persist_retry(state, recovery) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Unable to persist retry state for issue_id=#{recovery.issue_id}: #{inspect(reason)}")
    end
  end

  defp interrupted_run_error(%{session_unit: nil}), do: "Agent run was interrupted by a service restart"
  defp interrupted_run_error(_recovery), do: @handoff_recovery

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(state), terminal_state_set(state))
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(state), terminal_state_set(state))
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(state), terminal_state_set(state))
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, dispatch_state_set(state), terminal_state_set(state))
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, %State{}, nil)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{id: id}, %{running: running} = state, _active_states, _terminal_states)
       when is_map_key(running, id) and is_map_key(:erlang.map_get(id, running), :handoff_error), do: state

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      !issue_routable?(issue, state) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        entry = state.running[issue.id]
        state = terminate_running_issue(state, issue.id, false)

        if state.profile_id && entry && !state.running[issue.id],
          do: block_assignment_discrepancy(state, issue, entry),
          else: state

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      active_issue_state?(issue.state, active_states) ->
        reconcile_active_issue(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_active_issue(state, issue) do
    case Map.get(state.running, issue.id) do
      %{issue: previous} = entry ->
        if AgentRunner.same_agent_task?(previous, issue, settings(state).tracker, state.profile_id) do
          refresh_running_issue_state(state, issue)
        else
          handoff_running_issue(state, issue, entry)
        end

      _ ->
        state
    end
  end

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      state.blocked[issue.id][:routing_discrepancy] &&
          (!issue_routable?(issue, state) || !owned_workspace?(state, issue.id)) ->
        state

      state.blocked[issue.id][:routing_discrepancy] ->
        release_issue_claim(state, issue.id)

      !issue_routable?(issue, state) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        cleanup_issue_workspace(issue, Map.get(state.blocked, issue.id, %{}), state)
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{running: running} = state, issue_id, _cleanup_workspace)
       when is_map_key(running, issue_id) and is_map_key(:erlang.map_get(issue_id, running), :handoff_error), do: state

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        delete_retry(state, issue_id)
        release_issue_claim(state, issue_id)

      %{pid: _pid, ref: _ref, identifier: _identifier} = entry ->
        case stop_running_task(entry, state) do
          :ok ->
            finish_terminated_issue(state, issue_id, entry, cleanup_workspace)

          error ->
            hold_failed_handoff(state, entry.issue, entry, error)
        end

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp finish_terminated_issue(state, issue_id, entry, cleanup_workspace) do
    delete_retry(state, issue_id)
    state = record_session_completion_totals(state, entry)
    if cleanup_workspace, do: cleanup_issue_workspace(entry.issue, entry, state)

    %{
      state
      | running: Map.delete(state.running, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp handoff_running_issue(state, issue, entry) do
    # shortcut: polling can observe boundaries after writes; add mutation fencing for synchronous enforcement.
    Logger.info("Phase boundary handoff #{issue_context(issue)} phase_before=#{entry.issue.state} phase_after=#{issue.state} session_id=#{running_entry_session_id(entry)}")

    with :ok <- persist_retry(state, boundary_recovery(issue, entry)),
         :ok <- suspend_boundary_worker(entry),
         :ok <- stop_boundary_session(entry[:session_process]),
         :ok <- confirm_worker_stop(entry, state.task_supervisor, settings(state).codex.read_timeout_ms) do
      state = record_session_completion_totals(state, entry)
      Logger.info("Phase boundary stop confirmed #{issue_context(issue)} session_id=#{running_entry_session_id(entry)}")
      # Keep the recovery marker until the replacement persists its own recovery record.
      state = %{state | running: Map.delete(state.running, issue.id)}
      schedule_issue_retry(state, issue.id, 1, Map.put(boundary_recovery(issue, entry), :delay_type, :continuation))
    else
      error ->
        hold_failed_handoff(state, issue, entry, error)
    end
  end

  defp boundary_recovery(issue, entry) do
    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue_url: issue.url,
      attempt: normalize_retry_attempt(entry[:retry_attempt]),
      error: @handoff_recovery,
      worker_host: entry[:worker_host],
      workspace_path: entry[:workspace_path],
      infrastructure_failures: Map.get(entry, :infrastructure_failures, 0),
      retry_generation: entry[:retry_generation],
      reason_code: entry[:reason_code],
      retry_priority: entry[:retry_priority],
      session_unit: get_in(entry, [:session_process, :containment, :unit]),
      session_invocation: get_in(entry, [:session_process, :containment, :invocation])
    }
  end

  defp hold_failed_handoff(state, issue, entry, error) do
    Logger.error("Phase boundary stop unconfirmed #{issue_context(issue)} session_id=#{running_entry_session_id(entry)} reason=#{inspect(error)}; operator inspection required")
    held = entry |> Map.put(:handoff_error, inspect(error)) |> Map.put(:last_codex_message, @handoff_recovery <> ": " <> inspect(error))
    %{state | running: Map.put(state.running, issue.id, held)}
  end

  defp stop_boundary_session(%{containment: containment} = session) when is_map(containment), do: AppServer.stop_session(session)
  defp stop_boundary_session(_session), do: {:error, :session_process_unknown}

  defp suspend_boundary_worker(%{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: :erlang.suspend_process(pid)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp suspend_boundary_worker(_entry), do: {:error, :session_process_unknown}

  defp confirm_worker_stop(%{pid: pid} = entry, supervisor, read_timeout_ms) do
    monitor = Process.monitor(pid)
    terminate_task(pid, supervisor)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} ->
        if is_reference(entry[:ref]), do: Process.demonitor(entry.ref, [:flush])
        :ok
    after
      read_timeout_ms ->
        Process.demonitor(monitor, [:flush])
        {:error, :worker_stop_timeout}
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = settings(state).codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        state.running
        |> Enum.reject(fn {_id, entry} -> entry[:handoff_error] end)
        |> Enum.reduce(state, fn {issue_id, entry}, acc -> maybe_restart_stalled_issue(acc, issue_id, entry, now, timeout_ms) end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      if input_required_blocker?(running_entry) do
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)
      else
        retry_stalled_worker(state, running_entry, elapsed_ms, session_id)
      end
    else
      state
    end
  end

  defp retry_stalled_worker(state, entry, elapsed_ms, session_id) do
    reason =
      if HostResources.pressure(entry[:worker_host], elapsed_ms) == :pressured,
        do: "host_pressure_stall",
        else: "stalled"

    host_resources = HostResources.snapshot(entry[:worker_host])

    case stop_running_task(entry, state) do
      :ok ->
        # Keep the recovery record and claim until the replacement retry is durable.
        {entry, state} = pop_running_entry(state, entry.issue.id)
        state = record_session_completion_totals(state, entry)
        schedule_worker_failure(state, entry, "stalled for #{elapsed_ms}ms without codex activity", reason, host_resources)

      error ->
        Logger.warning(
          "Stalled worker cleanup unconfirmed #{issue_context(entry.issue)} session_id=#{session_id} " <>
            "reason=#{reason} host_resources=#{inspect(host_resources)}"
        )

        hold_failed_handoff(state, entry.issue, entry, error)
    end
  end

  defp defer_dispatch_retry(state, _issue, nil, _worker_host, _metadata), do: state

  defp defer_dispatch_retry(state, issue, attempt, worker_host, metadata) do
    state =
      schedule_issue_retry(
        state,
        issue.id,
        attempt,
        Map.merge(metadata, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: retry_error(metadata, "Runtime paused before retry dispatch"),
          worker_host: worker_host
        })
      )

    retry = Map.fetch!(state.retry_attempts, issue.id)
    Process.cancel_timer(retry.timer_ref)
    defer_retry(state, issue.id, retry.retry_token)
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid, task_supervisor) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid, _task_supervisor), do: :ok

  defp stop_entry_session(%{session_process: session}) when is_map(session), do: AppServer.stop_session(session)
  defp stop_entry_session(_entry), do: :ok

  defp stop_running_task(entry, state) do
    with :ok <- persist_retry(state, boundary_recovery(entry.issue, entry)),
         :ok <- if(is_map(entry[:session_process]), do: suspend_boundary_worker(entry), else: :ok),
         :ok <- stop_entry_session(entry) do
      confirm_worker_stop(entry, state.task_supervisor, settings(state).codex.read_timeout_ms)
    end
  end

  defp stop_and_block_issue(%State{} = state, issue_id, entry, error) do
    case stop_running_task(entry, state) do
      :ok -> block_issue_from_entry(state, issue_id, entry, error)
      stop_error -> hold_failed_handoff(state, entry.issue, entry, stop_error)
    end
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error) do
    delete_retry(state, issue_id)

    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      error: error,
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp choose_issues(issues, state) do
    dispatch_states = dispatch_state_set(state)
    terminal_states = terminal_state_set(state)

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if is_nil(quota_hold_reason(state_acc)) and
           should_dispatch_issue?(issue, state_acc, dispatch_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         issue,
         state,
         active_states,
         terminal_states
       ) do
    eligible_for_dispatch?(issue, state, active_states, terminal_states) and
      dispatch_capacity_available?(issue, state)
  end

  defp eligible_for_dispatch?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states, state) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      not pending_dispatch?(state, issue.id)
  end

  defp eligible_for_dispatch?(_issue, _state, _active_states, _terminal_states), do: false

  defp dispatch_capacity_available?(issue, state) do
    available_slots(state) > map_size(state.retry_attempts) + pending_retry_reads(state) and
      state_slots_available?(issue, state) and worker_slots_available?(state)
  end

  defp waiting_for_slots(state) do
    case state.candidate_snapshot do
      %{issues: issues, updated_at: updated_at} ->
        ready? = dispatch_ready?(state)
        quota_held? = not is_nil(quota_admission_error(state))
        dispatch_states = dispatch_state_set(state)
        terminal_states = terminal_state_set(state)

        waiting =
          issues
          |> sort_issues_for_dispatch()
          |> Enum.filter(fn issue ->
            ready? and eligible_for_dispatch?(issue, state, dispatch_states, terminal_states) and
              not retrying_issue?(state, issue.id) and
              (quota_held? or not dispatch_capacity_available?(issue, state))
          end)
          |> Enum.map(fn issue ->
            %{
              issue_id: issue.id,
              identifier: issue.identifier,
              issue_url: issue.url,
              title: issue.title,
              state: issue.state,
              priority: issue.priority
            }
          end)

        {waiting, updated_at}

      _ ->
        {[], nil}
    end
  end

  defp retrying_issue?(state, issue_id) do
    Map.has_key?(state.retry_attempts, issue_id) or
      Enum.any?(state.tracker_tasks, fn
        {_ref, %{purpose: {:retry, ^issue_id, _, _}}} -> true
        _ -> false
      end)
  end

  defp state_slots_available?(%Issue{state: issue_state}, %State{running: running} = state) do
    agent = settings(state).agent
    limit = Map.get(agent.max_concurrent_agents_by_state, normalize_issue_state(issue_state), agent.max_concurrent_agents)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states,
         state
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    Enum.all?([id, identifier, title, state_name], &present_string?/1) and
      issue_routable?(issue, state) and
      issue.admission_ready and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states, _state), do: false

  defp issue_routable?(%Issue{} = issue, state) do
    Issue.routable?(issue, settings(state).tracker.required_labels) and
      AgentRunner.operation_routable?(issue, state.profile_id)
  end

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set(state) do
    settings(state).tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set(state) do
    settings(state).tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_state_set(state) do
    settings(state).tracker.dispatch_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(state, issue, attempt \\ nil, metadata \\ %{}) do
    allowed = if is_nil(attempt), do: dispatch_state_set(state), else: retry_allowed_states(state, metadata)

    {:noreply, state} =
      start_tracker_read(state, {:dispatch, issue, attempt, metadata}, fn ->
        fetcher = &fetch_existing_issues(&1, state.profile_snapshot)
        refresh_issue_for_dispatch(issue, allowed, state, fetcher, attempt)
      end)

    state
  end

  defp refresh_issue_for_dispatch(issue, allowed_states, state, fetcher, attempt) do
    case revalidate_issue_for_dispatch(issue, fetcher, state, allowed_states) do
      {:ok, %Issue{} = refreshed_issue} ->
        context = %{issue_id: issue.id, identifier: issue.identifier, attempt: attempt}

        case AppServer.check_admission_quota(state.profile_snapshot, context) do
          :ok -> {:ok, refreshed_issue}
          {:error, reason} -> {:quota_deferred, refreshed_issue, reason}
        end

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        {:skip, :missing}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {:skip, refreshed_issue}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, metadata) do
    if dispatch_ready?(state) and dispatch_slots_available?(issue, state) do
      recipient = self()

      case select_worker_host(state, preferred_worker_host) do
        :no_worker_capacity ->
          Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
          state

        worker_host ->
          spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, metadata)
      end
    else
      defer_dispatch_retry(state, issue, attempt, preferred_worker_host, metadata)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, metadata) do
    metadata = current_retry_allowance(state, metadata)

    recovery = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue_url: issue.url,
      attempt: normalize_retry_attempt(attempt),
      error: retry_error(metadata, "Agent run was interrupted by a service restart"),
      worker_host: worker_host,
      workspace_path: metadata[:workspace_path],
      infrastructure_failures: Map.get(metadata, :infrastructure_failures, 0),
      retry_generation: metadata[:retry_generation],
      reason_code: metadata[:reason_code],
      retry_priority: metadata[:retry_priority]
    }

    case pin_instructions(state) do
      {:ok, pin} ->
        state = record_instructions_check(state, pin)
        claim_and_start_issue(state, issue, attempt, recipient, metadata, recovery, pin)

      {:error, reason} ->
        state = record_instructions_error(state, reason)
        defer_dispatch_retry(state, issue, attempt, worker_host, metadata)
    end
  end

  defp claim_and_start_issue(state, issue, attempt, recipient, metadata, recovery, pin) do
    worker_host = recovery.worker_host

    with :ok <- claim_assignment(state, issue.id),
         :ok <- persist_retry(state, recovery) do
      start_issue_child(state, issue, attempt, recipient, worker_host, metadata, pin)
    else
      {:error, reason} ->
        Logger.warning("Profile admission deferred #{issue_context(issue)} reason=#{safe_error(reason)}")

        if reason in [:assignment_owned_by_other_profile, :assignment_workspace_changed],
          do: block_assignment_discrepancy(state, issue, metadata),
          else: defer_dispatch_retry(state, issue, attempt, worker_host, metadata)
    end
  end

  defp start_issue_child(state, issue, attempt, recipient, worker_host, metadata, pin) do
    read_timeout = settings(state).codex.read_timeout_ms

    on_boundary = fn ->
      prepare_boundary(recipient, issue.id, read_timeout)
    end

    on_session_process = fn session ->
      GenServer.call(recipient, {:session_process, issue.id, self(), session}, read_timeout)
    end

    on_session_closed = fn ->
      GenServer.call(recipient, {:session_closed, issue.id, self()}, read_timeout)
    end

    on_after_run = fn ->
      GenServer.call(recipient, {:after_run, issue.id, self()}, read_timeout)
    end

    opts = [
      attempt: attempt,
      worker_host: worker_host,
      profile_snapshot: state.profile_snapshot,
      instructions: pin,
      on_boundary: on_boundary,
      on_session_process: on_session_process,
      on_session_closed: on_session_closed,
      on_after_run: on_after_run
    ]

    opts =
      if state.profile_id do
        callback = fn workspace ->
          GenServer.call(recipient, {:workspace_prepared, issue.id, self(), workspace}, read_timeout)
        end

        Keyword.put(opts, :on_workspace, callback)
      else
        opts
      end

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           AgentRunner.run(issue, recipient, opts)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            profile_snapshot: state.profile_snapshot,
            worker_host: worker_host,
            workspace_path: metadata[:workspace_path],
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            infrastructure_failures: Map.get(metadata, :infrastructure_failures, 0),
            retry_generation: metadata[:retry_generation],
            reason_code: metadata[:reason_code],
            retry_priority: metadata[:retry_priority],
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: retry_error(metadata, "failed to spawn agent: #{inspect(reason)}"),
          worker_host: worker_host
        })
    end
  end

  defp prepare_boundary(recipient, issue_id, read_timeout) do
    GenServer.call(recipient, {:prepare_boundary, issue_id, self()}, read_timeout)
  catch
    :exit, reason -> {:error, {:boundary_prepare_failed, reason}}
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, state, allowed_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        allowed_states = allowed_states || dispatch_state_set(state)

        if candidate_issue?(refreshed_issue, allowed_states, terminal_state_set(state), state) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _allowed_states, _terminal_states),
    do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id, preserve_recovery) do
    unless preserve_recovery, do: delete_retry(state, issue_id)

    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{running: running} = state, issue_id, _attempt, _metadata)
       when is_map_key(running, issue_id) and is_map_key(:erlang.map_get(issue_id, running), :handoff_error),
       do: state

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata, state)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    infrastructure_failures = Map.get(metadata, :infrastructure_failures, 0)
    retry_priority = metadata[:retry_priority] || System.system_time(:millisecond)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    reason_suffix = if metadata[:reason_code], do: " reason=#{metadata.reason_code}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{reason_suffix}")

    updated_state = %{
      state
      | claimed: MapSet.put(state.claimed, issue_id),
        retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            reason_code: metadata[:reason_code],
            worker_host: worker_host,
            workspace_path: workspace_path,
            infrastructure_failures: infrastructure_failures,
            retry_generation: metadata[:retry_generation],
            retry_priority: retry_priority
          })
    }

    write_scheduled_retry(updated_state, issue_id, metadata[:pause_reason])
  end

  defp write_scheduled_retry(state, issue_id, pause_reason) do
    retry = Map.fetch!(state.retry_attempts, issue_id)
    payload = Map.put(retry, :issue_id, issue_id)

    result =
      if pause_reason do
        RuntimeControl.pause_with_retry(control_id(state), payload, pause_reason, control_server(state))
      else
        persist_retry(state, payload)
      end

    updated =
      case result do
        :ok ->
          Map.delete(retry, :pending_write)

        {:error, reason} ->
          Logger.error("Unable to persist scheduled retry for issue_id=#{issue_id}: #{inspect(reason)}; deferring dispatch")
          Map.put(retry, :pending_write, pause_reason)
      end

    %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, updated)}
  end

  defp flush_retry_persistence(state) do
    Enum.reduce(state.retry_attempts, state, fn
      {issue_id, %{pending_write: pause_reason}}, acc -> write_scheduled_retry(acc, issue_id, pause_reason)
      _entry, acc -> acc
    end)
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          reason_code: Map.get(retry_entry, :reason_code),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          infrastructure_failures: Map.get(retry_entry, :infrastructure_failures, 0),
          retry_generation: retry_entry[:retry_generation],
          retry_priority: Map.get(retry_entry, :retry_priority)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(state, issue_id, attempt, metadata) do
    snapshot = state.profile_snapshot

    start_tracker_read(state, {:retry, issue_id, attempt, metadata}, fn ->
      fetch_existing_issues([issue_id], snapshot)
    end)
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set(state)

    cond do
      !issue_routable?(issue, state) ->
        state = release_issue_claim(state, issue_id)
        {:noreply, if(state.profile_id, do: block_assignment_discrepancy(state, issue, metadata), else: state)}

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue, metadata, state)
        {:noreply, release_issue_claim(state, issue_id)}

      String.starts_with?(metadata[:error] || "", @handoff_recovery) and
          not active_issue_state?(issue.state, dispatch_state_set(state)) ->
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states, state) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(issue, metadata, %State{profile_id: nil}), do: cleanup_issue_workspace(issue, metadata)

  defp cleanup_issue_workspace(%Issue{} = issue, metadata, state) do
    snapshot = metadata[:profile_snapshot] || state.profile_snapshot

    if snapshot && owned_workspace?(state, issue.id) do
      snapshot = Map.put(snapshot, :require_contained_hook, true)

      result =
        case metadata[:workspace_path] do
          path when is_binary(path) -> Workspace.remove_recorded(path, metadata[:worker_host], snapshot)
          _ -> Workspace.remove_issue_workspaces(issue, metadata[:worker_host], snapshot)
        end

      case result do
        {:error, _, _} -> Logger.warning("Profile workspace cleanup failed #{issue_context(issue)}")
        _ -> :ok
      end
    end
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(issue_or_identifier, metadata) when is_map(metadata) do
    case Map.get(metadata, :workspace_path) do
      workspace_path when is_binary(workspace_path) and workspace_path != "" ->
        Workspace.remove_recorded(workspace_path, Map.get(metadata, :worker_host))

      _ ->
        cleanup_issue_workspace(issue_or_identifier, Map.get(metadata, :worker_host))
    end
  end

  defp cleanup_issue_workspace(%Issue{} = issue, worker_host) do
    Workspace.remove_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_issue_or_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup(%State{retry_restore_pending: true}), do: :ok
  defp run_terminal_workspace_cleanup(%State{profile_id: id}) when is_binary(id), do: :ok

  defp run_terminal_workspace_cleanup(state) do
    case Tracker.fetch_issues_by_states(settings(state).tracker.terminal_states) do
      {:ok, issues} ->
        for %Issue{} = issue <- issues, issue_routable?(issue, state), not pending_handoff?(state.retry_attempts[issue.id]), do: cleanup_issue_workspace(issue)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp pending_handoff?(nil), do: false
  defp pending_handoff?(metadata), do: String.starts_with?(metadata[:error] || "", @handoff_recovery)

  defp block_assignment_discrepancy(state, issue, metadata) do
    blocked_entry = %{
      issue: issue,
      identifier: issue.identifier,
      workspace_path: metadata[:workspace_path],
      worker_host: metadata[:worker_host],
      error: "Assignment route or workspace differs from its recorded owner",
      routing_discrepancy: true,
      blocked_at: DateTime.utc_now()
    }

    %{state | blocked: Map.put(state.blocked, issue.id, blocked_entry), claimed: MapSet.put(state.claimed, issue.id)}
  end

  defp notify_dashboard(%State{profile_id: nil}), do: StatusDashboard.notify_update()
  defp notify_dashboard(%State{profile_id: id}), do: ObservabilityPubSub.broadcast_update(id)

  defp handle_active_retry(state, issue, attempt, metadata) do
    case quota_hold_reason(state) do
      nil -> dispatch_active_retry(state, issue, attempt, metadata)
      reason -> defer_admission(state, issue, attempt, quota_retry_metadata(metadata, reason))
    end
  end

  defp dispatch_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set(state), state) and
         dispatch_slots_available?(issue, state) and retry_priority_available?(state, issue.id, metadata) and
         retry_worker_available?(state, metadata) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           issue_url: issue.url || metadata[:issue_url],
           error: retry_error(metadata, "no available orchestrator slots")
         })
       )}
    end
  end

  defp retry_worker_available?(state, metadata) do
    host = select_worker_host(state, metadata[:worker_host])
    boundary = String.starts_with?(metadata[:error] || "", @handoff_recovery)
    host != :no_worker_capacity and (not boundary or host == metadata[:worker_host])
  end

  defp pending_retry_reads(state) do
    Enum.count(state.tracker_tasks, fn {_ref, task} -> match?({:retry, _, _, _}, task.purpose) end)
  end

  defp retry_priority_available?(state, issue_id, metadata) do
    priority = {metadata[:retry_priority] || 0, issue_id}

    waiting =
      Map.to_list(state.retry_attempts) ++
        Enum.flat_map(state.tracker_tasks, fn
          {_ref, %{purpose: {:retry, id, _attempt, meta}}} -> [{id, meta}]
          {_ref, %{purpose: {:dispatch, %{id: id}, attempt, meta}}} when is_integer(attempt) -> [{id, meta}]
          _ -> []
        end)

    ahead = waiting |> Enum.uniq_by(&elem(&1, 0)) |> Enum.count(fn {id, meta} -> id != issue_id and {meta[:retry_priority] || 0, id} < priority end)
    available_slots(state) > ahead
  end

  defp retry_allowed_states(state, meta) do
    if String.starts_with?(meta[:error] || "", @handoff_recovery) do
      dispatch_state_set(state)
    else
      active_state_set(state)
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    delete_retry(state, issue_id)
    state = remove_candidate(state, issue_id)

    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp retry_delay(attempt, metadata, state) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt, state)
    end
  end

  defp failure_retry_delay(attempt, state) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), settings(state).agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp retry_error(metadata, error) do
    if String.starts_with?(metadata[:error] || "", @handoff_recovery), do: @handoff_recovery <> ": " <> error, else: error
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case settings(state).worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case settings(state).worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp pending_dispatch?(state, issue_id) do
    Enum.any?(state.tracker_tasks, fn
      {_ref, %{purpose: {:dispatch, %{id: ^issue_id}, _, _}}} -> true
      _ -> false
    end)
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || settings(state).agent.max_concurrent_agents) -
        map_size(state.running) - Enum.count(state.tracker_tasks, fn {_ref, task} -> match?({:dispatch, _, _, _}, task.purpose) end),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    GenServer.call(server, :request_refresh)
  catch
    :exit, _reason -> :unavailable
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    GenServer.call(server, :snapshot, timeout)
  catch
    :exit, {:timeout, _} -> :timeout
    :exit, _ -> :unavailable
  end

  @impl true
  def handle_call({:workspace_prepared, issue_id, worker, workspace}, _from, state) do
    case state.running[issue_id] do
      %{pid: ^worker} = entry when not is_map_key(entry, :handoff_error) ->
        entry = Map.put(entry, :workspace_path, workspace)
        recovery = boundary_recovery(entry.issue, entry)
        result = persist_retry(state, Map.put(recovery, :error, interrupted_run_error(recovery)))

        if result == :ok do
          {:reply, :ok, put_in(state.running[issue_id], entry)}
        else
          {:reply, result, hold_failed_handoff(state, entry.issue, entry, result)}
        end

      _ ->
        {:reply, {:error, :stale_worker}, state}
    end
  end

  def handle_call({:session_process, issue_id, worker, session}, _from, state) do
    case state.running[issue_id] do
      %{pid: ^worker} = entry when not is_map_key(entry, :handoff_error) ->
        if Process.alive?(worker) do
          register_session_process(state, issue_id, entry, session)
        else
          {:reply, {:error, :stale_worker}, state}
        end

      _ ->
        {:reply, {:error, :stale_worker}, state}
    end
  end

  def handle_call({:after_run, issue_id, worker}, _from, state) do
    case state.running[issue_id] do
      %{pid: ^worker} = entry when not is_map_key(entry, :handoff_error) ->
        if is_nil(entry[:session_process]),
          do: {:reply, :ok, state},
          else: {:reply, {:error, :session_stop_unconfirmed}, state}

      _ ->
        {:reply, {:error, :stale_worker}, state}
    end
  end

  def handle_call({:session_closed, issue_id, worker}, _from, state) do
    case state.running[issue_id] do
      %{pid: ^worker} = entry when not is_map_key(entry, :handoff_error) ->
        entry = Map.put(entry, :session_process, nil)
        {:reply, :ok, %{state | running: Map.put(state.running, issue_id, entry)}}

      _ ->
        {:reply, {:error, :stale_worker}, state}
    end
  end

  def handle_call({:prepare_boundary, issue_id, worker}, _from, state) do
    case state.running[issue_id] do
      %{pid: ^worker} = entry when not is_map_key(entry, :handoff_error) ->
        case persist_retry(state, boundary_recovery(entry.issue, entry)) do
          :ok ->
            entry = Map.put(entry, :boundary_completed, true)
            {:reply, :ok, %{state | running: Map.put(state.running, issue_id, entry)}}

          error ->
            {:reply, error, hold_failed_handoff(state, entry.issue, entry, error)}
        end

      _ ->
        {:reply, {:error, :stale_worker}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)
    {waiting, waiting_updated_at} = waiting_for_slots(state)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          handoff_error: Map.get(metadata, :handoff_error),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          reason_code: Map.get(retry, :reason_code),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
      end)

    runtime_control =
      case RuntimeControl.status(control_server(state)) do
        {:ok, status} ->
          status

        {:error, reason} ->
          %{
            mode: :unknown,
            reason: "Runtime control unavailable",
            source: "system",
            active_turns: 0,
            quota_summary: nil,
            quota_checked_at: nil,
            database_error: if(state.profile_id, do: safe_error(reason), else: inspect(reason))
          }
      end

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       waiting: waiting,
       waiting_updated_at: waiting_updated_at,
       readiness: readiness(state, runtime_control),
       admission_error: quota_admission_error(state),
       instructions_revision: state.instructions_revision,
       max_concurrent_agents: state.max_concurrent_agents,
       runtime_control: runtime_control,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:workflow_update_ready, _from, %{profile_id: id} = state) when is_binary(id) do
    {:reply, {:error, "Use profile instructions activation for grouped runtime."}, state}
  end

  def handle_call(:workflow_update_ready, _from, state) do
    {:reply, workflow_update_ready(state), state}
  end

  def handle_call({:apply_workflow_update, _candidate}, _from, %{profile_id: id} = state) when is_binary(id) do
    {:reply, {:error, "Use profile instructions activation for grouped runtime."}, state}
  end

  def handle_call({:apply_workflow_update, candidate}, _from, state) do
    result = with :ok <- workflow_update_ready(state), do: WorkflowUpdate.apply(candidate)
    {:reply, result, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp register_session_process(state, issue_id, entry, session) do
    entry = Map.put(entry, :session_process, session)

    recovery = boundary_recovery(entry.issue, entry)

    recovery =
      if session[:containment],
        do: recovery,
        else: %{recovery | error: "Agent run was interrupted by a service restart"}

    case persist_retry(state, recovery) do
      :ok -> {:reply, :ok, %{state | running: Map.put(state.running, issue_id, entry)}}
      error -> {:reply, error, hold_failed_handoff(state, entry.issue, entry, error)}
    end
  end

  defp workflow_update_ready(%{running: running}) when map_size(running) > 0,
    do: {:error, "Runtime is busy. Retry the workflow update after agents finish."}

  defp workflow_update_ready(state) do
    if Enum.any?(state.tracker_tasks, fn {_ref, task} -> not match?({:poll, _, _}, task.purpose) end),
      do: {:error, "Runtime is checking admission. Retry the workflow update after tracker reads finish."},
      else: :ok
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp reset_successful_turn(state, %{infrastructure_failures: count} = entry, :turn_completed) when count > 0 do
    entry = %{entry | infrastructure_failures: 0}
    recovery = boundary_recovery(entry.issue, entry)
    persist_retry_state(state, Map.put(recovery, :error, interrupted_run_error(recovery)))
    entry
  end

  defp reset_successful_turn(_state, entry, _event), do: entry

  defp current_retry_allowance(%State{profile_id: nil}, metadata), do: metadata

  defp current_retry_allowance(state, metadata) do
    case RuntimeControl.status(control_server(state)) do
      {:ok, %{retry_generation: generation}} ->
        count =
          if (metadata[:retry_generation] || 0) == generation,
            do: metadata[:infrastructure_failures] || 0,
            else: 0

        Map.merge(metadata, %{infrastructure_failures: count, retry_generation: generation})

      _ ->
        metadata
    end
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        boundary_completed: event == :phase_boundary or Map.get(running_entry, :boundary_completed, false),
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{profile_id: nil} = state) do
    config = Config.settings!()
    apply_runtime_config(state, config)
  end

  defp refresh_runtime_config(%State{profile_id: id} = state) do
    with {:ok, snapshot} <- WorkflowStore.snapshot(id),
         {:ok, scope} <- JiraClient.assignment_scope(snapshot.settings.tracker),
         true <- snapshot.settings.worker.ssh_hosts == [] do
      quota_hold = if tracker_revision(state) == snapshot.revision, do: state.quota_hold
      state = %{state | profile_snapshot: snapshot, assignment_scope: scope, config_error: nil, quota_hold: quota_hold}
      apply_runtime_config(state, snapshot.settings)
    else
      false -> %{state | config_error: :profile_remote_workspace_unsupported, candidate_snapshot: nil}
      {:error, reason} -> %{state | config_error: safe_error(reason), candidate_snapshot: nil}
    end
  end

  defp apply_runtime_config(state, config) do
    candidate_snapshot =
      case state.candidate_snapshot do
        %{tracker: tracker} = snapshot when tracker == config.tracker -> snapshot
        _ -> nil
      end

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents,
        candidate_snapshot: candidate_snapshot
    }
  end

  defp settings(%State{profile_id: nil}), do: Config.settings!()
  defp settings(%State{profile_snapshot: %{settings: settings}}), do: settings

  defp tracker_revision(%State{profile_id: nil} = state), do: settings(state).tracker
  defp tracker_revision(%State{profile_snapshot: %{revision: revision}}), do: revision
  defp tracker_revision(_state), do: nil

  defp pin_instructions(%State{profile_id: nil}), do: {:ok, nil}

  defp pin_instructions(%State{profile_id: id, instructions: instructions} = state) do
    case instructions.pin(id) do
      {:ok, %{revision: revision, fingerprint: fingerprint}}
      when revision == state.instructions_revision and fingerprint != state.instructions_fingerprint ->
        {:error, :active_instructions_changed}

      result ->
        result
    end
  end

  defp refresh_instructions(%State{profile_id: nil} = state), do: state
  defp refresh_instructions(%State{config_error: error} = state) when not is_nil(error), do: state

  defp refresh_instructions(%State{instructions_revision: revision, instructions_check_at: checked, readiness_error: nil} = state)
       when is_integer(checked) do
    now = System.monotonic_time(:millisecond)

    if now < checked and state.instructions.status(state.profile_id) == {:ok, %{revision: revision}} do
      state
    else
      validate_instructions(state)
    end
  end

  defp refresh_instructions(state), do: validate_instructions(state)

  defp validate_instructions(state) do
    case pin_instructions(state) do
      {:ok, pin} -> record_instructions_check(state, pin)
      {:error, reason} -> record_instructions_error(state, reason)
    end
  end

  defp record_instructions_check(%State{profile_id: nil} = state, nil), do: state

  defp record_instructions_check(state, pin) do
    %{
      state
      | readiness_error: nil,
        instructions_revision: pin.revision,
        instructions_fingerprint: pin.fingerprint,
        instructions_check_at: System.monotonic_time(:millisecond) + @instructions_check_interval_ms
    }
  end

  defp record_instructions_error(state, reason), do: %{state | readiness_error: safe_error(reason)}

  defp readiness(state, runtime_control) do
    error =
      state.config_error || state.readiness_error || state.recovery_error ||
        if(runtime_control.mode == :unknown,
          do: :runtime_control_unavailable,
          else: if(state.retry_restore_pending and state.profile_id, do: :recovery_pending)
        ) || assignment_readiness_error(state)

    %{ready: is_nil(error), error: error}
  end

  defp assignment_readiness_error(%State{assignment_scope: nil}), do: nil

  defp assignment_readiness_error(state) do
    case AssignmentOwners.ready(state.assignment_scope) do
      :ok -> nil
      {:error, reason} -> safe_error(reason)
    end
  end

  defp safe_error(reason) when is_atom(reason), do: reason
  defp safe_error({reason, _}) when is_atom(reason), do: reason
  defp safe_error(_reason), do: :profile_runtime_error

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states, state) do
    candidate_issue?(issue, active_state_set(state), terminal_states, state)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
