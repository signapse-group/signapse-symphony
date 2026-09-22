defmodule SymphonyElixir.GitHub.Project do
  @moduledoc """
  Organization Projects v2 read boundary. Project Status becomes Issue.state;
  native issue state and project identities remain in native_ref.
  """

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Tracker.Issue

  @query """
  query SymphonyProject($owner: String!, $number: Int!, $after: String) {
    organization(login: $owner) {
      projectV2(number: $number) {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField { id options { id name } }
        }
        items(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id isArchived
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
            }
            content {
              __typename
              ... on Issue {
                id number title body state url createdAt updatedAt
                repository { nameWithOwner }
                issueType { name }
              }
            }
          }
        }
      }
    }
  }
  """

  @spec configured?(map()) :: boolean()
  def configured?(%{provider: provider}) when is_map(provider) do
    Map.has_key?(provider, "project_owner") or Map.has_key?(provider, "project_number")
  end

  def configured?(_settings), do: false

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{provider: provider} = settings) do
    with :ok <- validate_project_scope(provider),
         :ok <- validate_state_list(settings.dispatch_states, :invalid_github_dispatch_states),
         :ok <- validate_state_list(settings.active_states, :invalid_github_active_states),
         :ok <- validate_optional_state(Map.get(settings, :review_state), :invalid_github_review_state) do
      validate_state_list(settings.terminal_states, :invalid_github_terminal_states)
    end
  end

  defp validate_project_scope(provider) do
    cond do
      not present?(provider["project_owner"]) -> {:error, :missing_github_project_owner}
      not (is_integer(provider["project_number"]) and provider["project_number"] > 0) -> {:error, :invalid_github_project_number}
      not string_list?(provider["issue_types"]) or provider["issue_types"] == [] -> {:error, :invalid_github_issue_types}
      true -> :ok
    end
  end

  defp validate_state_list(states, error) do
    if string_list?(states), do: :ok, else: {:error, error}
  end

  defp validate_optional_state(nil, _error), do: :ok

  defp validate_optional_state(state, error) when is_binary(state) do
    if String.trim(state) == "", do: {:error, error}, else: :ok
  end

  defp validate_optional_state(_state, error), do: {:error, error}

  @spec fetch(map(), function(), {:states | :ids, [String.t()]}) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch(_settings, _request_fun, {_selection, []}), do: {:ok, []}

  def fetch(settings, request_fun, selection) do
    with :ok <- validate_config(settings),
         {:ok, issues} <- pages(settings, request_fun, nil, [], []) do
      {:ok, select(issues, selection)}
    end
  end

  @spec pages(map(), function(), String.t() | nil, [String.t()], [[Issue.t()]]) ::
          {:ok, [Issue.t()]} | {:error, term()}
  defp pages(settings, request_fun, cursor, seen, acc) do
    provider = settings.provider
    body = %{"query" => @query, "variables" => %{"owner" => provider["project_owner"], "number" => provider["project_number"], "after" => cursor}}

    with {:ok, response} <- Client.request("POST", "/graphql", %{}, body, tracker_settings: settings, request_fun: request_fun),
         {:ok, project} <- project_payload(response),
         :ok <- validate_statuses(project, settings),
         %{"nodes" => nodes, "pageInfo" => info} when is_list(nodes) <- project["items"],
         {:ok, issues} <- normalize_page(nodes, project, provider) do
      continue_pages(info, settings, request_fun, seen, [issues | acc])
    else
      {:error, _} = error -> error
      _ -> {:error, :github_project_unknown_payload}
    end
  end

  @spec continue_pages(map(), map(), function(), [String.t()], [[Issue.t()]]) ::
          {:ok, [Issue.t()]} | {:error, term()}
  defp continue_pages(%{"hasNextPage" => false}, _settings, _request_fun, _seen, acc) do
    {:ok, acc |> Enum.reverse() |> List.flatten()}
  end

  defp continue_pages(%{"hasNextPage" => true, "endCursor" => cursor}, settings, request_fun, seen, acc)
       when is_binary(cursor) and cursor != "" do
    if cursor in seen do
      {:error, :github_project_repeated_cursor}
    else
      pages(settings, request_fun, cursor, [cursor | seen], acc)
    end
  end

  defp continue_pages(_info, _settings, _request_fun, _seen, _acc), do: {:error, :github_project_invalid_pagination}

  defp project_payload(%{status: 200, body: %{"errors" => errors}}) when errors != [],
    do: {:error, {:github_graphql_errors, errors}}

  defp project_payload(%{status: 200, body: %{"data" => %{"organization" => %{"projectV2" => %{"id" => id} = project}}}})
       when is_binary(id), do: {:ok, project}

  defp project_payload(%{status: status}) when status != 200, do: {:error, {:github_api_status, status}}
  defp project_payload(_response), do: {:error, :github_project_unavailable}

  defp validate_statuses(%{"field" => %{"id" => id, "options" => options}}, settings)
       when is_binary(id) and is_list(options) do
    names = Enum.map(options, &normalize(&1["name"]))

    configured_states =
      settings.dispatch_states ++ settings.active_states ++ settings.terminal_states ++
        List.wrap(Map.get(settings, :review_state))

    if Enum.all?(configured_states, &(normalize(&1) in names)) do
      :ok
    else
      {:error, :github_project_unknown_status}
    end
  end

  defp validate_statuses(_project, _settings), do: {:error, :github_project_missing_status_field}

  defp normalize_page(nodes, project, provider) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case normalize_item(node, project, provider) do
        {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
        :skip -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp normalize_item(%{"isArchived" => true}, _project, _provider), do: :skip

  defp normalize_item(%{"content" => %{"__typename" => "Issue"} = content} = item, project, provider) do
    if get_in(content, ["repository", "nameWithOwner"]) == provider["repo"] do
      build_issue(item, content, project, provider)
    else
      :skip
    end
  end

  defp normalize_item(%{"content" => _}, _project, _provider), do: :skip
  defp normalize_item(_item, _project, _provider), do: {:error, :github_project_unknown_payload}

  defp build_issue(item, content, project, provider) do
    status = get_in(item, ["fieldValueByName", "name"])
    type = get_in(content, ["issueType", "name"])
    number = content["number"]

    cond do
      type not in provider["issue_types"] ->
        :skip

      is_integer(number) and number > 0 and present?(content["title"]) and present?(item["id"]) and
          content["state"] in ["OPEN", "CLOSED"] ->
        {:ok,
         %Issue{
           id: Integer.to_string(number),
           identifier: "GH-#{number}",
           title: content["title"],
           description: content["body"],
           url: content["url"],
           state: status,
           native_ref: %{
             "node_id" => content["id"],
             "number" => number,
             "repo" => provider["repo"],
             "project_id" => project["id"],
             "project_item_id" => item["id"],
             "status_field_id" => project["field"]["id"],
             "issue_type" => type,
             "issue_state" => content["state"]
           },
           dispatchable: content["state"] == "OPEN" and present?(status),
           created_at: datetime(content["createdAt"]),
           updated_at: datetime(content["updatedAt"])
         }}

      true ->
        {:error, :github_project_unknown_payload}
    end
  end

  defp select(issues, {:states, states}) do
    normalized = Enum.map(states, &normalize/1)
    Enum.filter(issues, &(normalize(&1.state) in normalized))
  end

  defp select(issues, {:ids, ids}) do
    by_id = Map.new(issues, &{&1.id, &1})

    ids
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case Map.fetch(by_id, id) do
        {:ok, issue} -> [issue]
        :error -> []
      end
    end)
  end

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp datetime(_value), do: nil
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp string_list?(values) when is_list(values), do: Enum.all?(values, &present?/1)
  defp string_list?(_values), do: false
end
