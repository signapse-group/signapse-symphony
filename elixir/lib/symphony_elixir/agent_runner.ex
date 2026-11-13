defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Profile, PromptBuilder, RuntimeControl, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil
  @qa_operations ~w(qa-generate qa-execute qa-retest)

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher, Config.settings!().tracker, nil)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    snapshot = opts[:profile_snapshot]

    if snapshot do
      metadata = [
        profile_id: snapshot.profile_id,
        workflow_revision: snapshot.revision,
        instructions_revision: opts[:instructions].revision
      ]

      Logger.metadata(metadata)
    end

    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), settings(snapshot).worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_assignment(issue, codex_update_recipient, opts, worker_host, snapshot) do
      :ok ->
        :ok

      {:error, :session_heartbeat_expired} ->
        exit(:session_heartbeat_expired)

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")

        if quota_limit_error?(reason) do
          RuntimeControl.pause("Codex usage limit exceeded", "quota", control_server(snapshot))
        end

        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_assignment(issue, recipient, opts, host, nil), do: run_on_worker_host(issue, recipient, opts, host)

  defp run_assignment(issue, recipient, opts, host, snapshot) do
    control = control_server(snapshot)

    with {:ok, permit} <- RuntimeControl.acquire_turn(control) do
      try do
        run_on_worker_host(issue, recipient, opts, host)
      after
        RuntimeControl.release_turn(permit, control)
      end
    end
  end

  defp quota_limit_error?(reason) do
    message = inspect(reason, limit: :infinity, printable_limit: 4_000) |> String.downcase()

    Enum.any?(
      ["usage_limit_exceeded", "usagelimitexceeded", "usage limit exceeded", "usage limit reached"],
      &String.contains?(message, &1)
    )
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    snapshot = workspace_snapshot(opts)
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case create_workspace(issue, worker_host, snapshot) do
      {:ok, workspace} ->
        result =
          try do
            with :ok <- record_workspace(opts, codex_update_recipient, issue, worker_host, workspace),
                 :ok <- run_workspace_hook(:run_before_run_hook, workspace, issue, worker_host, snapshot) do
              run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
            end
          catch
            :exit, {:session_not_started, _} = reason ->
              exit(reason)

            :exit, {:session_stop_unconfirmed, _} = reason ->
              exit(reason)

            kind, reason ->
              finish_after_run_hook(workspace, issue, worker_host, opts)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        finish_after_run_hook(workspace, issue, worker_host, opts)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_workspace(opts, recipient, issue, host, workspace) do
    if opts[:on_workspace], do: :ok, else: send_worker_runtime_info(recipient, issue, host, workspace)
  end

  defp finish_after_run_hook(workspace, issue, worker_host, opts) do
    snapshot = workspace_snapshot(opts)

    if is_binary(settings(snapshot).hooks.after_run) do
      case Keyword.get(opts, :on_after_run, fn -> :ok end).() do
        :ok -> run_workspace_hook(:run_after_run_hook, workspace, issue, worker_host, snapshot)
        error -> exit({:session_stop_unconfirmed, error})
      end
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, Map.put(message, :worker_pid, self())})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         worker_pid: self(),
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    snapshot = opts[:profile_snapshot]
    max_turns = Keyword.get(opts, :max_turns, settings(snapshot).agent.max_turns)
    issue_state_fetcher = Keyword.get_lazy(opts, :issue_state_fetcher, fn -> issue_fetcher(snapshot) end)

    on_started =
      Keyword.get(opts, :on_session_process, fn session_process ->
        if is_pid(codex_update_recipient) do
          send(codex_update_recipient, {:worker_runtime_info, issue.id, %{worker_pid: self(), session_process: session_process}})
        end

        :ok
      end)

    on_stopped = Keyword.get(opts, :on_session_closed, fn -> :ok end)

    session_opts = [
      worker_host: worker_host,
      profile_snapshot: snapshot,
      instructions: opts[:instructions],
      on_started: on_started,
      on_stopped: on_stopped,
      lifecycle_owner: codex_update_recipient
    ]

    with {:ok, session} <- AppServer.start_session(workspace, session_opts) do
      AppServer.with_session(
        session,
        fn ->
          do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
        end,
        issue: issue,
        on_stopped: on_stopped
      )
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      tracker = settings(opts[:profile_snapshot]).tracker
      profile_id = opts[:profile_snapshot] && opts[:profile_snapshot].profile_id

      case continue_with_issue?(issue, issue_state_fetcher, tracker, profile_id) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, refreshed_issue} ->
          finish_assignment(app_session, workspace, issue, refreshed_issue, codex_update_recipient, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp finish_assignment(session, workspace, issue, refreshed, recipient, opts) do
    snapshot = opts[:profile_snapshot]

    if same_agent_task?(issue, refreshed, settings(snapshot).tracker, snapshot && snapshot.profile_id) do
      :ok
    else
      recovery = %{
        issue_id: issue.id,
        identifier: issue.identifier,
        issue_url: issue.url,
        attempt: Keyword.get(opts, :attempt) || 1,
        error: "Phase boundary handoff requires operator confirmation",
        worker_host: session.worker_host,
        workspace_path: workspace
      }

      prepare_boundary = Keyword.get(opts, :on_boundary, fn -> RuntimeControl.persist_retry(RuntimeControl.runtime_id(), recovery) end)

      case prepare_boundary.() do
        :ok -> send_codex_update(recipient, issue, %{event: :phase_boundary, timestamp: DateTime.utc_now()})
        {:error, reason} -> exit({:session_stop_unconfirmed, {:recovery_persist_failed, reason}})
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    case opts[:instructions] do
      nil -> PromptBuilder.build_prompt(issue, opts)
      pin -> recovery_prompt(PromptBuilder.build_prompt(issue, opts[:attempt], pin), opts)
    end
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Continue only the assignment given to this session. Finish after its configured phase boundary transition and readback; a new session owns the next phase.
    - Within the same assignment, focus on the remaining work until it is complete or you are blocked.
    """
  end

  defp recovery_prompt(prompt, opts) do
    if opts[:attempt] && opts[:attempt] > 0 do
      prompt <>
        """


        Before any external write, reconcile the current Jira issue, the existing workspace and branch,
        PR, and prior run evidence. Continue the recorded assignment from its current phase. Reuse
        existing results and do not repeat writes already applied.
        """
    else
      prompt
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, tracker, profile_id) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        same_phase = same_agent_task?(issue, refreshed_issue, tracker, profile_id)
        eligible = active_issue_state?(refreshed_issue.state, tracker) and Issue.routable?(refreshed_issue, tracker.required_labels)

        if same_phase and eligible do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _tracker, _profile_id), do: {:done, issue}

  @spec same_agent_task?(Issue.t(), Issue.t()) :: boolean()
  def same_agent_task?(issue, refreshed_issue), do: same_agent_task?(issue, refreshed_issue, Config.settings!().tracker, nil)

  @spec same_agent_task?(Issue.t(), Issue.t(), map(), String.t() | nil) :: boolean()
  def same_agent_task?(issue, refreshed_issue, tracker, profile_id) do
    same_boundary?(issue, refreshed_issue, tracker) and same_operation?(issue, refreshed_issue, profile_id)
  end

  @doc false
  @spec operation_routable?(Issue.t(), String.t() | nil) :: boolean()
  def operation_routable?(issue, "qa"), do: match?([_], qa_operations(issue))
  def operation_routable?(_issue, _profile_id), do: true

  defp same_boundary?(issue, refreshed_issue, tracker) do
    [tracker.review_state | tracker.session_boundary_states]
    |> Enum.filter(&is_binary/1)
    |> Enum.all?(fn state ->
      boundary_state = normalize_issue_state(state)

      (is_binary(issue.state) and normalize_issue_state(issue.state) == boundary_state) ==
        (is_binary(refreshed_issue.state) and normalize_issue_state(refreshed_issue.state) == boundary_state)
    end)
  end

  defp same_operation?(issue, refreshed, "qa"), do: qa_operations(issue) == qa_operations(refreshed)
  defp same_operation?(_issue, _refreshed, _profile), do: true
  defp qa_operations(issue), do: Enum.filter(@qa_operations, &(&1 in issue.labels))

  defp active_issue_state?(state_name, tracker) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name, _tracker), do: false

  defp settings(nil), do: Config.settings!()
  defp settings(%{settings: settings}), do: settings

  defp workspace_snapshot(opts) do
    case opts[:profile_snapshot] do
      nil ->
        nil

      snapshot ->
        snapshot
        |> Map.put(:instructions, opts[:instructions])
        |> Map.put(:workspace_prepared, opts[:on_workspace])
        |> Map.put(:hook_started, opts[:on_session_process])
        |> Map.put(:hook_stopped, opts[:on_session_closed])
    end
  end

  defp control_server(nil), do: RuntimeControl
  defp control_server(%{profile_id: id}), do: Profile.via(id, :runtime_control)

  defp issue_fetcher(nil), do: &Tracker.fetch_issues_by_ids/1
  defp issue_fetcher(%{settings: %{tracker: tracker}}), do: &Tracker.fetch_issues_by_ids(&1, tracker)

  defp create_workspace(issue, host, nil), do: Workspace.create_for_issue(issue, host)
  defp create_workspace(issue, host, snapshot), do: checked_hook_result(Workspace.create_for_issue(issue, host, snapshot))

  defp run_workspace_hook(hook, workspace, issue, host, nil), do: apply(Workspace, hook, [workspace, issue, host])

  defp run_workspace_hook(hook, workspace, issue, host, snapshot),
    do: checked_hook_result(apply(Workspace, hook, [workspace, issue, host, snapshot]))

  defp checked_hook_result({:error, {:session_stop_unconfirmed, _reason} = error}), do: exit(error)
  defp checked_hook_result(result), do: result

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
