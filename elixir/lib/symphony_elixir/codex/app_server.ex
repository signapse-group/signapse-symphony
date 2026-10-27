defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Codex.SessionProcess, Config, PathSafety, RuntimeControl, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @rate_limits_read_id 4
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @type session :: %{
          port: port(),
          containment: map() | nil,
          heartbeat: pid() | nil,
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          dynamic_tool_binding: map()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        case stop_session(session) do
          :ok -> :ok
          {:error, reason} -> exit({:session_stop_unconfirmed, reason})
        end
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    dynamic_tool_binding = DynamicTool.bind()

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, session_process} <- start_port(expanded_workspace, worker_host, dynamic_tool_binding, opts) do
      port = session_process.port
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id} <-
             do_start_session(port, expanded_workspace, session_policies, dynamic_tool_binding) do
        {:ok,
         %{
           port: port,
           containment: session_process.containment,
           heartbeat: session_process.heartbeat,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host,
           dynamic_tool_binding: dynamic_tool_binding
         }}
      else
        {:error, reason} ->
          error = stop_failed_start(session_process, reason)
          Keyword.get(opts, :on_stopped, fn -> :ok end).()
          error
      end
    else
      {:error, _} = error ->
        Keyword.get(opts, :on_stopped, fn -> :ok end).()
        error
    end
  end

  defp stop_failed_start(session, reason) do
    case stop_session(session) do
      :ok -> {:error, reason}
      {:error, stop_reason} -> exit({:session_stop_unconfirmed, stop_reason})
    end
  end

  @spec read_rate_limits() :: {:ok, map()} | {:error, term()}
  def read_rate_limits do
    dynamic_tool_binding = DynamicTool.bind()
    deadline = response_deadline()

    with {:ok, port} <- open_port(System.tmp_dir!(), nil, dynamic_tool_binding, false) do
      try do
        with :ok <- send_initialize(port, deadline),
             :ok <- request_rate_limits(port),
             {:ok, result} <- await_response(port, @rate_limits_read_id, deadline) do
          quota_result(result)
        end
      after
        stop_port(port)
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{dynamic_tool_binding: dynamic_tool_binding} = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    runtime_control = Keyword.get(opts, :runtime_control, RuntimeControl)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, dynamic_tool_binding, issue: issue)
      end)

    with {:ok, permit} <- RuntimeControl.acquire_turn(runtime_control) do
      try do
        result = run_admitted_turn(session, prompt, issue, on_message, tool_executor)

        if quota_limit_error?(result) do
          RuntimeControl.pause("Codex usage limit exceeded", "quota", runtime_control)
        end

        result
      after
        RuntimeControl.release_turn(permit, runtime_control)
      end
    end
  end

  defp run_admitted_turn(
         %{
           port: port,
           metadata: metadata,
           approval_policy: approval_policy,
           auto_approve_requests: auto_approve_requests,
           turn_sandbox_policy: turn_sandbox_policy,
           thread_id: thread_id,
           workspace: workspace
         },
         prompt,
         issue,
         on_message,
         tool_executor
       ) do
    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  defp request_rate_limits(port) do
    send_message(port, %{"method" => "account/rateLimits/read", "id" => @rate_limits_read_id})
    :ok
  end

  defp quota_result(%{"rateLimitsByLimitId" => limits}) when is_map(limits) and map_size(limits) > 0 do
    assess_rate_limits(limits)
  end

  defp quota_result(%{"rateLimitsByLimitId" => limits}) when not is_nil(limits),
    do: {:error, :codex_rate_limits_missing}

  defp quota_result(%{"rateLimits" => limits}) when is_map(limits), do: assess_rate_limits(%{"codex" => limits})
  defp quota_result(_result), do: {:error, :codex_rate_limits_missing}

  defp assess_rate_limits(limits) do
    result =
      Enum.reduce_while(limits, {:ok, []}, fn {limit_id, limit}, {:ok, observations} ->
        case quota_bucket(limit_id, limit) do
          {:ok, windows} -> {:cont, {:ok, observations ++ windows}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, observations} <- result do
      exhausted? = Enum.any?(observations, fn {_id, used, _reset} -> used == 100 end)
      {:ok, %{available?: not exhausted?, summary: format_quota_summary(observations)}}
    end
  end

  defp quota_bucket(limit_id, limit) when is_map(limit) do
    with {:ok, primary} <- quota_window(limit_id, "primary", Map.get(limit, "primary")),
         {:ok, secondary} <- quota_window(limit_id, "secondary", Map.get(limit, "secondary")) do
      observations = primary ++ secondary

      cond do
        not is_nil(Map.get(limit, "rateLimitReachedType")) ->
          {:ok, [{limit_id, 100, nil} | observations]}

        observations == [] ->
          {:error, {:codex_quota_usage_unavailable, limit_id}}

        true ->
          {:ok, observations}
      end
    end
  end

  defp quota_bucket(limit_id, _limit), do: {:error, {:codex_quota_usage_unavailable, limit_id}}

  # Null windows represent an absent quota window in the app-server protocol.
  # A present window must have a valid percentage; another window cannot mask it.
  defp quota_window(_limit_id, _window_name, nil), do: {:ok, []}

  defp quota_window(limit_id, _window_name, %{"usedPercent" => used} = window)
       when is_number(used) and used >= 0 and used <= 100 do
    {:ok, [{limit_id, used, Map.get(window, "resetsAt")}]}
  end

  defp quota_window(limit_id, window_name, _window) do
    {:error, {:codex_quota_window_invalid, limit_id, window_name}}
  end

  defp format_quota_summary(observations) do
    observations
    |> Enum.map_join(", ", fn {limit_id, used, reset_at} ->
      reset = format_reset_time(reset_at)
      "#{limit_id}: #{used}%#{reset}"
    end)
  end

  defp format_reset_time(reset_at) when is_integer(reset_at) do
    case DateTime.from_unix(reset_at) do
      {:ok, datetime} -> " (resets #{DateTime.to_iso8601(datetime)})"
      {:error, _reason} -> ""
    end
  end

  defp format_reset_time(_reset_at), do: ""

  @spec stop_session(map()) :: :ok | {:error, term()}
  def stop_session(%{containment: containment} = session) when is_map(containment) do
    with :ok <- SessionProcess.stop(session) do
      if is_port(session[:port]), do: stop_port(session.port), else: :ok
    end
  end

  def stop_session(%{port: port, containment: nil}) when is_port(port), do: stop_port(port)
  def stop_session(_session), do: {:error, :session_process_unknown}

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding, opts) do
    tracker = Config.settings!().tracker
    containment = if is_binary(tracker.review_state) or tracker.session_boundary_states != [], do: SessionProcess.new()
    on_started = Keyword.get(opts, :on_started, fn _ -> :ok end)
    session = %{port: nil, containment: containment, heartbeat: nil, worker_host: worker_host}
    # Register ownership before a host can create any session processes.
    try do
      :ok = on_started.(session)
    catch
      kind, reason -> exit({:session_not_started, {kind, reason}})
    end

    with {:ok, port} <- open_port(workspace, worker_host, dynamic_tool_binding, containment || false) do
      heartbeat = if containment, do: SessionProcess.heartbeat(port, Keyword.get(opts, :lifecycle_owner))
      session = %{session | port: port, heartbeat: heartbeat}

      if containment do
        await_containment(session, on_started)
      else
        :ok = on_started.(session)
        {:ok, session}
      end
    end
  end

  defp await_containment(%{port: port} = session, on_started) do
    receive do
      {^port, {:data, {:eol, "SYMPHONY_CGROUP:" <> invocation}}} ->
        if String.match?(invocation, ~r/^[0-9a-f]{32}$/) do
          session = put_in(session.containment.invocation, invocation)
          :ok = on_started.(session)
          true = Port.command(port, "SYMPHONY_START\n")
          {:ok, session}
        else
          stop_failed_start(session, :invalid_session_containment)
        end

      {^port, {:data, _data}} ->
        stop_failed_start(session, :session_containment_start_failed)

      {^port, {:exit_status, status}} ->
        stop_failed_start(session, port_exit_reason(status))
    after
      Config.settings!().codex.read_timeout_ms ->
        stop_failed_start(session, :session_containment_timeout)
    end
  end

  defp open_port(workspace, nil, dynamic_tool_binding, isolated) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      command = isolated_launch_command(local_launch_command(dynamic_tool_binding), isolated, workspace)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            env: tracker_secret_port_env(dynamic_tool_binding),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp open_port(workspace, worker_host, dynamic_tool_binding, isolated) when is_binary(worker_host) do
    remote_command =
      [
        tracker_secret_unset_command(dynamic_tool_binding),
        isolated_launch_command(remote_launch_command(workspace, dynamic_tool_binding), isolated, workspace)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" && ")

    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp isolated_launch_command(command, false, _workspace), do: command
  defp isolated_launch_command(command, containment, workspace), do: SessionProcess.launch_command(containment, command, workspace)

  defp local_launch_command(dynamic_tool_binding) do
    [
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, dynamic_tool_binding) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command(dynamic_tool_binding) do
    case dynamic_tool_binding.secret_environment_names |> valid_environment_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port, deadline \\ response_deadline()) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id, deadline) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies, dynamic_tool_binding) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies, dynamic_tool_binding)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         dynamic_tool_binding
       ) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => dynamic_tool_binding.tool_specs
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp port_exit_reason(75), do: :session_heartbeat_expired
  defp port_exit_reason(status), do: {:port_exit, status}

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, port_exit_reason(status)}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        handle_completed_turn(port, on_message, payload, payload_string)

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp handle_completed_turn(port, on_message, payload, payload_string) do
    case completed_turn_result(payload) do
      {:ok, _turn} = result ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        result

      {:error, reason} ->
        emit_turn_event(on_message, :turn_failed, payload, payload_string, port, reason)
        {:error, {:turn_failed, reason}}
    end
  end

  defp completed_turn_result(payload) do
    turn =
      get_in(payload, ["params", "turn"]) ||
        Map.get(payload, "turn")

    case turn do
      %{"status" => "failed"} -> {:error, Map.get(turn, "error", turn)}
      %{"status" => "interrupted"} -> {:error, {:turn_interrupted, Map.get(turn, "error")}}
      _ -> {:ok, :turn_completed}
    end
  end

  defp quota_limit_error?({:error, reason}) do
    message = inspect(reason, limit: :infinity, printable_limit: 4_000) |> String.downcase()

    Enum.any?(
      ["usage_limit_exceeded", "usagelimitexceeded", "usage limit exceeded", "usage limit reached"],
      &String.contains?(message, &1)
    )
  end

  defp quota_limit_error?(_result), do: false

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         _port,
         _id,
         _params,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ),
       do: :input_required

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    if String.starts_with?(question_id, "mcp_tool_call_approval_") do
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label}
      end
    else
      :error
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp response_deadline do
    System.monotonic_time(:millisecond) + Config.settings!().codex.read_timeout_ms
  end

  defp await_response(port, request_id, deadline \\ response_deadline()) do
    with_timeout_response(port, request_id, deadline, "")
  end

  defp with_timeout_response(port, request_id, deadline, pending_line) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      {:error, :response_timeout}
    else
      receive_response(port, request_id, deadline, pending_line, remaining_ms)
    end
  end

  defp receive_response(port, request_id, deadline, pending_line, remaining_ms) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, deadline)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, deadline, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, port_exit_reason(status)}
    after
      remaining_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, deadline) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, deadline, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, deadline, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
