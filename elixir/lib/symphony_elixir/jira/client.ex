defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira Cloud REST client for project-scoped issue polling.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @page_size 100
  @issue_fields [
    "summary",
    "description",
    "status",
    "labels",
    "assignee",
    "created",
    "updated",
    "project",
    "issuetype",
    "parent",
    "issuelinks"
  ]

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    ["JIRA_API_TOKEN" | env_reference_names([provider["api_token"]])]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    fetch_issues_by_states(states, Config.settings!().tracker, &perform_request/5)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids) when is_list(ids) do
    fetch_issues_by_ids(ids, Config.settings!().tracker, &perform_request/5)
  end

  @spec request(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(method, path, query, body, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(query) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, jira_settings} <- settings(tracker_settings) do
      request_fun.(method, path, query, body, jira_settings)
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, tracker_settings)
      when is_map(issue) and is_map(tracker_settings) do
    case settings(tracker_settings) do
      {:ok, jira_settings} -> normalize_issue(issue, jira_settings)
      _ -> nil
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(states, tracker_settings, request_fun)
      when is_list(states) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_states(states, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(ids, tracker_settings, request_fun)
      when is_list(ids) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_ids(ids, tracker_settings, request_fun)
  end

  defp fetch_issues_by_states([], _tracker_settings, _request_fun), do: {:ok, []}

  defp fetch_issues_by_states(states, tracker_settings, request_fun) do
    with {:ok, jira_settings} <- settings(tracker_settings) do
      fetch_state_pages(states, jira_settings, nil, request_fun, [])
    end
  end

  defp fetch_state_pages(states, settings, next_page_token, request_fun, pages) do
    body =
      %{
        "jql" => state_jql(settings, states),
        "fields" => @issue_fields,
        "maxResults" => @page_size
      }
      |> maybe_put("nextPageToken", next_page_token)

    with {:ok, payload} <-
           request_with_settings(
             "POST",
             "/rest/api/3/search/jql",
             %{},
             body,
             settings,
             request_fun
           ),
         {:ok, raw_issues, next_token} <- state_page(payload) do
      issues = normalize_candidate_page(raw_issues, settings, states)
      updated_pages = [issues | pages]

      case next_token do
        :done -> {:ok, updated_pages |> Enum.reverse() |> List.flatten()}
        token -> fetch_state_pages(states, settings, token, request_fun, updated_pages)
      end
    end
  end

  defp fetch_issues_by_ids([], _tracker_settings, _request_fun), do: {:ok, []}

  defp fetch_issues_by_ids(ids, tracker_settings, request_fun) do
    with {:ok, jira_settings} <- settings(tracker_settings) do
      ids
      |> Enum.uniq()
      |> Enum.chunk_every(@page_size)
      |> fetch_id_batches(jira_settings, request_fun, [])
    end
  end

  defp fetch_id_batches([], _settings, _request_fun, pages) do
    {:ok, pages |> Enum.reverse() |> List.flatten()}
  end

  defp fetch_id_batches([ids | rest], settings, request_fun, pages) do
    body = %{"issueIdsOrKeys" => ids, "fields" => @issue_fields}

    with {:ok, payload} <-
           request_with_settings(
             "POST",
             "/rest/api/3/issue/bulkfetch",
             %{},
             body,
             settings,
             request_fun
           ),
         {:ok, raw_issues} <- issues_payload(payload),
         {:ok, issues} <- normalize_requested_issues(raw_issues, ids, settings) do
      fetch_id_batches(rest, settings, request_fun, [issues | pages])
    end
  end

  defp state_page(%{"issues" => issues, "isLast" => true}) when is_list(issues) do
    {:ok, issues, :done}
  end

  defp state_page(%{"issues" => issues, "isLast" => false, "nextPageToken" => token})
       when is_list(issues) and is_binary(token) and token != "" do
    {:ok, issues, token}
  end

  defp state_page(%{"issues" => issues, "isLast" => false}) when is_list(issues) do
    {:error, :jira_missing_next_page_token}
  end

  defp state_page(_payload), do: {:error, :jira_unknown_payload}

  defp issues_payload(%{"issues" => issues}) when is_list(issues), do: {:ok, issues}
  defp issues_payload(_payload), do: {:error, :jira_unknown_payload}

  defp normalize_candidate_page(raw_issues, settings, states) do
    requested_states = states |> Enum.map(&normalize_state/1) |> MapSet.new()
    issues = Enum.map(raw_issues, &normalize_issue(&1, settings))
    malformed_count = Enum.count(issues, &is_nil/1)

    if malformed_count > 0 do
      Logger.warning("Dropping malformed Jira issue records count=#{malformed_count}")
    end

    issues
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn issue ->
      MapSet.member?(requested_states, normalize_state(issue.state)) and
        (settings.issue_types == [] or Issue.routable?(issue, settings.required_labels))
    end)
  end

  defp normalize_requested_issues(raw_issues, requested_ids, settings) do
    requested = MapSet.new(requested_ids)

    raw_issues
    |> Enum.reduce_while({:ok, %{}}, fn raw_issue, {:ok, issues_by_id} ->
      normalize_requested_issue(raw_issue, requested, settings, issues_by_id)
    end)
    |> case do
      {:ok, issues_by_id} ->
        {:ok, Enum.flat_map(requested_ids, &(Map.fetch(issues_by_id, &1) |> fetched_issue()))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_requested_issue(%{"id" => id} = raw_issue, requested, settings, issues_by_id)
       when is_binary(id) do
    project_key = issue_project_key(raw_issue)

    cond do
      not MapSet.member?(requested, id) ->
        {:cont, {:ok, issues_by_id}}

      is_nil(project_key) ->
        {:halt, {:error, :jira_unknown_payload}}

      not same_project_key?(project_key, settings.project_key) ->
        {:cont, {:ok, issues_by_id}}

      true ->
        case normalize_issue(raw_issue, settings) do
          %Issue{} = issue -> {:cont, {:ok, Map.put(issues_by_id, id, issue)}}
          nil -> {:halt, {:error, :jira_unknown_payload}}
        end
    end
  end

  defp normalize_requested_issue(_raw_issue, _requested, _settings, _issues_by_id) do
    {:halt, {:error, :jira_unknown_payload}}
  end

  defp fetched_issue({:ok, issue}), do: [issue]
  defp fetched_issue(:error), do: []

  defp normalize_issue(%{"id" => id, "key" => key, "fields" => fields}, settings)
       when is_binary(id) and is_binary(key) and is_map(fields) do
    title = fields["summary"]
    state = issue_status(fields)["name"]
    status_category = status_category(issue_status(fields))
    blockers = extract_blockers(fields["issuelinks"])
    native_ref = native_ref(fields)
    labels = extract_labels(fields["labels"])
    selection_error = selection_error(native_ref, labels, settings)

    if same_project_key?(issue_project_key(%{"fields" => fields}), settings.project_key) and
         present_string?(id) and
         present_string?(key) and present_string?(title) and present_string?(state) do
      log_selection_error(selection_error, id, key)

      %Issue{
        id: id,
        native_ref: native_ref,
        identifier: key,
        title: title,
        description: description_text(fields["description"]),
        priority: nil,
        state: state,
        branch_name: nil,
        url: "#{settings.base_url}/browse/#{URI.encode(key, &URI.char_unreserved?/1)}",
        assignee_id: get_in(fields, ["assignee", "accountId"]),
        labels: labels,
        blocked_by: blockers,
        dispatchable: is_nil(selection_error) and dispatchable?(state, status_category, blockers, settings),
        admission_ready: dependencies_ready?(fields["issuelinks"], blockers, settings),
        created_at: parse_datetime(fields["created"]),
        updated_at: parse_datetime(fields["updated"])
      }
    end
  end

  defp normalize_issue(_issue, _settings), do: nil

  defp log_selection_error(nil, _id, _key), do: :ok

  defp log_selection_error(reason, id, key) do
    Logger.warning("Skipping Jira issue outside worker scope: issue_id=#{id} issue_identifier=#{key} reason=#{reason}")
  end

  defp native_ref(fields) do
    type = fields["issuetype"]
    parent = fields["parent"]

    if is_map(type) or is_map(parent) do
      %{
        issue_type: issue_type_ref(type),
        parent: parent_ref(parent)
      }
    end
  end

  defp issue_type_ref(%{"id" => id, "name" => name, "subtask" => subtask})
       when is_binary(id) and is_binary(name) and is_boolean(subtask) do
    if present_string?(id) and present_string?(name), do: %{id: id, name: name, subtask: subtask}
  end

  defp issue_type_ref(_type), do: nil

  defp parent_ref(%{"id" => id, "key" => key}) when is_binary(id) and is_binary(key) do
    if present_string?(id) and present_string?(key), do: %{id: id, key: key}
  end

  defp parent_ref(_parent), do: nil

  defp selection_error(native_ref, labels, settings) do
    type = if is_map(native_ref), do: native_ref.issue_type

    cond do
      settings.issue_types != [] and not selected_type?(type, settings.issue_types) -> :issue_type
      settings.routing_labels != [] and not valid_subtask?(native_ref) -> :subtask_parent
      settings.routing_labels != [] and Enum.filter(labels, &(&1 in settings.routing_labels)) != settings.worker_routes -> :routing_labels
      true -> nil
    end
  end

  defp valid_subtask?(%{issue_type: %{subtask: true}, parent: parent}) when is_map(parent), do: true
  defp valid_subtask?(_native_ref), do: false

  defp dependencies_ready?(_links, _blockers, %{routing_labels: []}), do: true

  defp dependencies_ready?(links, blockers, _settings) when is_list(links) do
    Enum.all?(links, fn
      %{"type" => %{"name" => name}} -> present_string?(name)
      _ -> false
    end) and Enum.all?(blockers, &(present_string?(&1.id) and present_string?(&1.identifier) and &1[:status_category] == "done"))
  end

  defp dependencies_ready?(_links, _blockers, _settings), do: false

  defp selected_type?(%{id: id, name: name}, types) do
    Enum.any?(types, &(normalize_state(&1) in [normalize_state(id), normalize_state(name)]))
  end

  defp selected_type?(_type, _types), do: false

  defp description_text(nil), do: nil

  defp description_text(value) when is_binary(value) do
    blank_to_nil(value)
  end

  defp description_text(value) when is_map(value) do
    value
    |> adf_text()
    |> blank_to_nil()
  end

  defp description_text(_value), do: nil

  defp adf_text(%{"type" => "hardBreak"}), do: "\n"

  defp adf_text(%{"text" => text, "marks" => marks}) when is_binary(text) and is_list(marks) do
    urls = for %{"type" => "link", "attrs" => %{"href" => url}} <- marks, is_binary(url) and url != text, do: url
    Enum.reduce(Enum.uniq(urls), text, fn url, acc -> acc <> " (#{url})" end)
  end

  defp adf_text(%{"text" => text}) when is_binary(text), do: text

  defp adf_text(%{"type" => type, "content" => content})
       when type in ["paragraph", "heading", "blockquote"] and is_list(content) do
    Enum.map_join(content, "", &adf_text/1) <> "\n"
  end

  defp adf_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "", &adf_text/1)
  end

  defp adf_text(%{"attrs" => attrs}) when is_map(attrs) do
    attrs["text"] || attrs["shortName"] || attrs["url"] || ""
  end

  defp adf_text(_value), do: ""

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp extract_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_labels), do: []

  defp extract_blockers(links) when is_list(links) do
    Enum.flat_map(links, &extract_blocker/1)
  end

  defp extract_blockers(_links), do: []

  defp extract_blocker(%{"type" => %{"name" => type_name}, "inwardIssue" => blocker_issue})
       when is_binary(type_name) do
    if normalize_state(type_name) == "blocks" do
      [blocker_ref(blocker_issue)]
    else
      []
    end
  end

  defp extract_blocker(%{"type" => %{"name" => type_name}} = link) when is_binary(type_name) do
    if normalize_state(type_name) == "blocks" and not is_map(link["outwardIssue"]), do: [blocker_ref(nil)], else: []
  end

  defp extract_blocker(_link), do: []

  defp blocker_ref(blocker_issue) when is_map(blocker_issue) do
    status = issue_status(blocker_issue["fields"])

    %{
      id: optional_string(blocker_issue["id"]),
      identifier: optional_string(blocker_issue["key"]),
      state: optional_string(status["name"])
    }
    |> maybe_put(:status_category, status_category(status))
  end

  defp blocker_ref(_blocker), do: %{id: nil, identifier: nil, state: nil}

  defp issue_status(%{"status" => status}) when is_map(status), do: status
  defp issue_status(_fields), do: %{}

  defp status_category(%{"statusCategory" => %{"key" => key}}), do: optional_string(key)
  defp status_category(_status), do: nil

  defp dispatchable?(_state, _status_category, _blockers, %{routing_labels: [_ | _]}), do: true

  defp dispatchable?(state, status_category, blockers, %{terminal_states: terminal_states}) do
    not blocks_gate_dispatch?(state, status_category) or
      Enum.all?(blockers, &terminal_blocker?(&1, terminal_states))
  end

  defp blocks_gate_dispatch?(_state, status_category)
       when is_binary(status_category) and status_category != "" do
    normalize_state(status_category) == "new"
  end

  defp blocks_gate_dispatch?(state, _status_category) do
    normalize_state(state) in ["todo", "to do"]
  end

  defp terminal_blocker?(%{state: state}, terminal_states)
       when is_binary(state) and is_list(terminal_states) do
    normalize_state(state) in terminal_states
  end

  defp terminal_blocker?(_blocker, _terminal_states), do: false

  defp issue_project_key(raw_issue), do: get_in(raw_issue, ["fields", "project", "key"])

  defp same_project_key?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  defp same_project_key?(_left, _right), do: false

  defp parse_datetime(value) when is_binary(value) do
    normalized = Regex.replace(~r/([+-]\d{2})(\d{2})$/, value, "\\1:\\2")

    case DateTime.from_iso8601(normalized) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp request_with_settings(method, path, query, body, settings, request_fun) do
    case request_fun.(method, path, query, body, settings) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %{status: status}} when is_integer(status) ->
        Logger.error("Jira API request failed status=#{status} method=#{method} path=#{path}")
        {:error, {:jira_api_status, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :jira_unknown_payload}
    end
  end

  defp perform_request(method, path, query, body, settings) do
    with {:ok, request_method} <- request_method(method) do
      request_opts = [
        method: request_method,
        url: settings.base_url <> path,
        headers: jira_headers(settings.email, settings.api_token),
        params: query,
        connect_options: [timeout: 30_000]
      ]

      request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

      case Req.request(request_opts) do
        {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
        {:error, reason} -> {:error, {:jira_api_request, reason}}
      end
    end
  end

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    base_url = resolve_setting(provider["base_url"], System.get_env("JIRA_BASE_URL"))
    email = resolve_setting(provider["email"], System.get_env("JIRA_EMAIL"))
    api_token = resolve_setting(provider["api_token"], System.get_env("JIRA_API_TOKEN"))
    project_key = resolve_setting(provider["project_key"], nil)

    cond do
      not valid_base_url?(base_url) ->
        {:error, :invalid_jira_base_url}

      not present_string?(email) ->
        {:error, :missing_jira_email}

      not present_string?(api_token) ->
        {:error, :missing_jira_api_token}

      not present_string?(project_key) ->
        {:error, :missing_jira_project_key}

      true ->
        with {:ok, types} <- configured_names(provider, "issue_types", :invalid_jira_issue_types),
             {:ok, routes} <- configured_names(provider, "routing_labels", :invalid_jira_routing_labels),
             routes = routes |> Enum.map(&normalize_state/1) |> Enum.uniq(),
             required_labels = extract_labels(Map.get(tracker_settings, :required_labels, [])),
             worker_routes = Enum.filter(required_labels, &(&1 in routes)),
             :ok <- validate_routing(types, routes, worker_routes) do
          {:ok,
           %{
             base_url: String.trim_trailing(base_url, "/"),
             email: email,
             api_token: api_token,
             project_key: project_key,
             issue_types: types,
             routing_labels: routes,
             worker_routes: worker_routes,
             required_labels: required_labels,
             terminal_states: terminal_states(tracker_settings)
           }}
        end
    end
  end

  defp configured_names(provider, key, error) do
    case Map.fetch(provider, key) do
      :error ->
        {:ok, []}

      {:ok, values} when is_list(values) and values != [] ->
        if Enum.all?(values, &present_string?/1), do: {:ok, values |> Enum.map(&String.trim/1) |> Enum.uniq()}, else: {:error, error}

      _ ->
        {:error, error}
    end
  end

  defp validate_routing(_types, [], _worker_routes), do: :ok
  defp validate_routing([_ | _], [_ | _], [_]), do: :ok
  defp validate_routing(_types, _routes, _worker_routes), do: {:error, :invalid_jira_routing_config}

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env_name, fallback) do
    if valid_env_name?(env_name) do
      normalize_string(System.get_env(env_name) || fallback)
    else
      nil
    end
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp optional_string(value) when is_binary(value) do
    if present_string?(value), do: value, else: nil
  end

  defp optional_string(_value), do: nil

  defp terminal_states(%{terminal_states: states}) when is_list(states) do
    states
    |> Enum.map(&normalize_state/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp terminal_states(_tracker_settings), do: []

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env_name when is_binary(env_name) -> if valid_env_name?(env_name), do: [env_name], else: []
      _ -> []
    end)
  end

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_base_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, query: nil, fragment: nil} when is_binary(host) -> true
      _ -> false
    end
  end

  defp valid_base_url?(_value), do: false

  defp jira_headers(email, api_token) do
    [
      {"Accept", "application/json"},
      {"Authorization", "Basic #{Base.encode64("#{email}:#{api_token}")}"}
    ]
  end

  defp state_jql(settings, states) do
    quoted_states = Enum.map_join(states, ", ", &jql_string/1)
    type_clause = if settings.issue_types == [], do: "", else: " AND issuetype IN (#{Enum.map_join(settings.issue_types, ", ", &jql_string/1)})"
    label_clauses = Enum.map_join(settings.required_labels, "", &(" AND labels = " <> jql_string(&1)))
    "project = #{jql_string(settings.project_key)} AND status IN (#{quoted_states})" <> type_clause <> label_clauses
  end

  defp jql_string(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp request_method("GET"), do: {:ok, :get}
  defp request_method("POST"), do: {:ok, :post}
  defp request_method("PUT"), do: {:ok, :put}
  defp request_method("DELETE"), do: {:ok, :delete}
  defp request_method(_method), do: {:error, :invalid_jira_method}

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
