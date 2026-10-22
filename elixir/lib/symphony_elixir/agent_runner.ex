defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, PromptBuilder, RuntimeControl, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")

        if quota_limit_error?(reason) do
          RuntimeControl.pause("Codex usage limit exceeded", "quota")
        end

        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
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
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          finish_after_run_hook(workspace, issue, worker_host, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_after_run_hook(workspace, issue, worker_host, opts) do
    if is_binary(Config.settings!().hooks.after_run) do
      case Keyword.get(opts, :on_after_run, fn -> :ok end).() do
        :ok -> Workspace.run_after_run_hook(workspace, issue, worker_host)
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
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

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
      on_started: on_started,
      on_stopped: on_stopped,
      lifecycle_owner: codex_update_recipient
    ]

    with {:ok, session} <- AppServer.start_session(workspace, session_opts) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        case AppServer.stop_session(session) do
          :ok -> on_stopped.()
          {:error, reason} -> exit({:session_stop_unconfirmed, reason})
        end
      end
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

      case continue_with_issue?(issue, issue_state_fetcher) do
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
    if same_agent_task?(issue, refreshed) do
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

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

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

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) and same_agent_task?(issue, refreshed_issue) do
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

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  @spec same_agent_task?(Issue.t(), Issue.t()) :: boolean()
  def same_agent_task?(issue, refreshed_issue) do
    tracker = Config.settings!().tracker

    [tracker.review_state | tracker.session_boundary_states]
    |> Enum.filter(&is_binary/1)
    |> Enum.all?(fn state ->
      boundary_state = normalize_issue_state(state)

      (is_binary(issue.state) and normalize_issue_state(issue.state) == boundary_state) ==
        (is_binary(refreshed_issue.state) and normalize_issue_state(refreshed_issue.state) == boundary_state)
    end)
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

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
