defmodule SymphonyElixir.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.GitHub.AgentTool, as: GitHubAgentTool
  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.GitHub.Project, as: GitHubProject

  defmodule FakeGitHubClient do
    def fetch_issues_by_states(states) do
      send(self(), {:github_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:github_ids_called, ids})
      {:ok, ids}
    end
  end

  setup do
    github_client_module = Application.get_env(:symphony_elixir, :github_client_module)

    on_exit(fn ->
      if is_nil(github_client_module) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, github_client_module)
      end
    end)

    :ok
  end

  test "adapter validates GitHub config, delegates reads, and advertises github_api" do
    settings = tracker_settings()

    assert :ok = GitHubAdapter.validate_config(settings)

    assert {:error, :missing_github_active_states} =
             GitHubAdapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_github_terminal_states} =
             GitHubAdapter.validate_config(%{settings | terminal_states: nil})

    assert :ok = GitHubAdapter.validate_config(%{settings | active_states: [], terminal_states: []})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: ["Todo"]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: [42]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: ["closed"]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | terminal_states: ["open"]})

    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    assert {:ok, ["open"]} = GitHubAdapter.fetch_issues_by_states(["open"])
    assert_receive {:github_states_called, ["open"]}

    assert {:ok, ["42"]} = GitHubAdapter.fetch_issues_by_ids(["42"])
    assert_receive {:github_ids_called, ["42"]}

    assert [%{"name" => "github_api"}] = GitHubAdapter.agent_tool_specs()

    assert GitHubAdapter.execute_agent_tool(
             "github_api",
             %{"method" => "GET", "path" => "/user"},
             github_client: fn _method, _path, _params, _body, _opts ->
               {:ok, %{status: 200, body: %{"login" => "octocat"}}}
             end
           )["success"]
  end

  test "client validates repository settings and declares token environments" do
    assert :ok = GitHubClient.validate_settings(tracker_settings())

    assert {:error, :missing_github_repo} =
             GitHubClient.validate_settings(tracker_settings(%{"repo" => 123}))

    assert {:error, :invalid_github_repo} =
             GitHubClient.validate_settings(tracker_settings(%{"repo" => "not-a-repo"}))

    assert {:error, :missing_github_token} =
             GitHubClient.validate_settings(tracker_settings(%{"token" => 123}))

    assert {:error, :invalid_github_api_url} =
             GitHubClient.validate_settings(tracker_settings(%{"api_url" => "not a url"}))

    assert {:error, :invalid_github_api_url} =
             GitHubClient.validate_settings(tracker_settings(%{"api_url" => "http://api.github.com"}))

    assert GitHubClient.secret_environment_names(tracker_settings(%{"token" => "$SYMPHONY_GITHUB_TOKEN"})) == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN",
             "SYMPHONY_GITHUB_TOKEN"
           ]
  end

  test "client normalizes GitHub issues without dropping provider details" do
    issue = GitHubClient.normalize_issue_for_test(raw_issue(42), "octo/repo")

    assert issue.id == "42"
    assert issue.identifier == "GH-42"

    assert issue.native_ref == %{
             "id" => 1_042,
             "node_id" => "I_42",
             "number" => 42,
             "repo" => "octo/repo"
           }

    assert issue.title == "Issue 42"
    assert issue.description == "Body 42"
    assert issue.state == "open"
    assert issue.url == "https://github.test/octo/repo/issues/42"
    assert issue.assignee_id == "octocat"
    assert issue.labels == ["bug", "platform"]
    assert issue.blocked_by == []
    assert issue.dispatchable
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at

    refute GitHubClient.normalize_issue_for_test(
             Map.put(raw_issue(43), "pull_request", %{"url" => "https://api.github.test/pulls/43"}),
             "octo/repo"
           ).dispatchable

    assert GitHubClient.normalize_issue_for_test(
             Map.put(raw_issue(44), "title", " "),
             "octo/repo"
           ) == nil
  end

  test "client pages state reads, filters requested states, and drops malformed records" do
    first_page =
      Enum.map(1..97, &raw_issue/1) ++
        [
          Map.put(raw_issue(98), "pull_request", %{"url" => "https://api.github.test/pulls/98"}),
          Map.put(raw_issue(99), "state", "closed"),
          Map.put(raw_issue(100), "title", "")
        ]

    request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, settings ->
      send(self(), {:github_page, params, settings})

      body =
        case params["page"] do
          1 -> first_page
          2 -> [raw_issue(101)]
        end

      {:ok, %{status: 200, body: body}}
    end

    log =
      capture_log(fn ->
        assert {:ok, issues} =
                 GitHubClient.fetch_issues_by_states_for_test(
                   [" OPEN "],
                   tracker_settings(),
                   request_fun
                 )

        assert length(issues) == 99
        assert hd(issues).id == "1"
        assert List.last(issues).id == "101"
        refute Enum.any?(issues, &(&1.id == "99"))
        assert Enum.find(issues, &(&1.id == "98")).dispatchable == false
      end)

    assert log =~ "Dropping malformed GitHub issue records count=1"

    assert_receive {:github_page,
                    %{
                      "state" => "open",
                      "per_page" => 100,
                      "page" => 1,
                      "sort" => "created",
                      "direction" => "asc"
                    }, %{repo: "octo/repo"}}

    assert_receive {:github_page, %{"page" => 2}, %{repo: "octo/repo"}}

    assert {:ok, []} =
             GitHubClient.fetch_issues_by_states_for_test(
               ["In Progress"],
               tracker_settings(),
               fn _method, _path, _params, _body, _settings ->
                 flunk("unsupported GitHub states should not make an HTTP request")
               end
             )
  end

  test "client refreshes numeric IDs in order, omits 404s, and rejects malformed refreshes" do
    request_fun = fn "GET", path, %{}, nil, _settings ->
      send(self(), {:github_id_path, path})

      case path do
        "/repos/octo/repo/issues/2" -> {:ok, %{status: 200, body: raw_issue(2)}}
        "/repos/octo/repo/issues/1" -> {:ok, %{status: 200, body: raw_issue(1)}}
        "/repos/octo/repo/issues/404" -> {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
      end
    end

    assert {:ok, issues} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["2", "1", "404", "2"],
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.id) == ["2", "1"]
    assert_receive {:github_id_path, "/repos/octo/repo/issues/2"}
    assert_receive {:github_id_path, "/repos/octo/repo/issues/1"}
    assert_receive {:github_id_path, "/repos/octo/repo/issues/404"}
    refute_receive {:github_id_path, "/repos/octo/repo/issues/2"}

    assert {:error, :invalid_github_issue_id} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["not-a-number"],
               tracker_settings(),
               request_fun
             )

    assert {:error, :github_unknown_payload} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["3"],
               tracker_settings(),
               fn _method, _path, _params, _body, _settings ->
                 {:ok, %{status: 200, body: Map.put(raw_issue(3), "title", "")}}
               end
             )
  end

  test "project mode dispatches only configured Task items in Ready and refreshes active IDs" do
    settings = project_tracker_settings()
    assert :ok = GitHubAdapter.validate_config(settings)

    request_fun = fn "POST", "/graphql", %{}, body, request_settings ->
      send(self(), {:github_project_query, body, request_settings})
      {:ok, %{status: 200, body: project_response()}}
    end

    assert {:ok, [ready]} =
             GitHubClient.fetch_issues_by_states_for_test(["Ready"], settings, request_fun)

    assert ready.id == "1"
    assert ready.state == "Ready"
    assert ready.native_ref["issue_type"] == "Task"
    assert ready.native_ref["project_item_id"] == "PVTI_1"
    assert ready.dispatchable

    assert {:ok, [active]} =
             GitHubClient.fetch_issues_by_ids_for_test(["2"], settings, request_fun)

    assert active.id == "2"
    assert active.state == "In progress"
    assert active.dispatchable

    assert_received {:github_project_query,
                     %{
                       "variables" => %{
                         "owner" => "signapse-group",
                         "number" => 1,
                         "after" => nil
                       }
                     }, %{repo: "signapse-group/signapse"}}
  end

  test "project mode validates configuration and skips empty selections" do
    settings = project_tracker_settings()

    refute GitHubProject.configured?(%{})

    assert {:ok, []} =
             GitHubProject.fetch(settings, fn _, _, _, _, _ -> flunk("unexpected request") end, {:states, []})

    assert {:error, :missing_github_project_owner} =
             GitHubProject.validate_config(put_in(settings, [:provider, "project_owner"], " "))

    assert {:error, :invalid_github_project_number} =
             GitHubProject.validate_config(put_in(settings, [:provider, "project_number"], 0))

    assert {:error, :invalid_github_issue_types} =
             GitHubProject.validate_config(put_in(settings, [:provider, "issue_types"], []))

    assert {:error, :invalid_github_dispatch_states} =
             GitHubProject.validate_config(%{settings | dispatch_states: nil})

    assert {:error, :invalid_github_active_states} =
             GitHubProject.validate_config(%{settings | active_states: [42]})

    assert {:error, :invalid_github_review_state} =
             GitHubProject.validate_config(%{settings | review_state: " "})

    assert {:error, :invalid_github_terminal_states} =
             GitHubProject.validate_config(%{settings | terminal_states: [""]})
  end

  test "project mode paginates and normalizes supported issue items" do
    settings = project_tracker_settings()

    closed =
      project_item(4, "Task", "Done")
      |> put_in(["content", "state"], "CLOSED")
      |> put_in(["content", "createdAt"], "invalid")
      |> put_in(["content", "updatedAt"], nil)

    archived = Map.put(project_item(5, "Task", "Ready"), "isArchived", true)
    other_repo = put_in(project_item(6, "Task", "Ready"), ["content", "repository", "nameWithOwner"], "other/repo")
    draft = %{"content" => %{"__typename" => "DraftIssue"}}

    request_fun = fn "POST", "/graphql", %{}, body, _request_settings ->
      case get_in(body, ["variables", "after"]) do
        nil ->
          response =
            project_response()
            |> put_in(["data", "organization", "projectV2", "items", "nodes"], [archived, other_repo, draft])
            |> put_in(["data", "organization", "projectV2", "items", "pageInfo"], %{
              "hasNextPage" => true,
              "endCursor" => "next"
            })

          {:ok, %{status: 200, body: response}}

        "next" ->
          response =
            project_response()
            |> put_in(["data", "organization", "projectV2", "items", "nodes"], [closed])

          {:ok, %{status: 200, body: response}}
      end
    end

    assert {:ok, [issue]} = GitHubProject.fetch(settings, request_fun, {:ids, ["4", "missing", "4"]})
    assert issue.id == "4"
    refute issue.dispatchable
    assert issue.created_at == nil
    assert issue.updated_at == nil
  end

  test "project mode reports API, payload, status, item, and pagination failures" do
    settings = project_tracker_settings()
    request = fn response -> fn _, _, _, _, _ -> response end end

    assert {:error, :request_failed} =
             GitHubProject.fetch(settings, request.({:error, :request_failed}), {:states, ["Ready"]})

    assert {:error, {:github_graphql_errors, [%{"message" => "bad query"}]}} =
             GitHubProject.fetch(
               settings,
               request.({:ok, %{status: 200, body: %{"errors" => [%{"message" => "bad query"}]}}}),
               {:states, ["Ready"]}
             )

    assert {:error, {:github_api_status, 500}} =
             GitHubProject.fetch(settings, request.({:ok, %{status: 500, body: %{}}}), {:states, ["Ready"]})

    assert {:error, :github_project_unavailable} =
             GitHubProject.fetch(settings, request.({:ok, %{status: 200, body: %{}}}), {:states, ["Ready"]})

    assert_project_error(settings, :github_project_missing_status_field, fn response ->
      put_in(response, ["data", "organization", "projectV2", "field"], nil)
    end)

    assert_project_error(%{settings | dispatch_states: ["Unknown"]}, :github_project_unknown_status, & &1)

    assert_project_error(%{settings | review_state: "Unknown"}, :github_project_unknown_status, & &1)

    assert_project_error(settings, :github_project_unknown_status, fn response ->
      put_in(response, ["data", "organization", "projectV2", "field", "options"], [%{}])
    end)

    assert_project_error(settings, :github_project_unknown_payload, fn response ->
      put_in(response, ["data", "organization", "projectV2", "items"], %{})
    end)

    assert_project_error(settings, :github_project_unknown_payload, fn response ->
      put_in(response, ["data", "organization", "projectV2", "items", "nodes"], [%{}])
    end)

    assert_project_error(settings, :github_project_unknown_payload, fn response ->
      invalid = put_in(project_item(7, "Task", "Ready"), ["content", "title"], "")
      put_in(response, ["data", "organization", "projectV2", "items", "nodes"], [invalid])
    end)

    assert_project_error(settings, :github_project_invalid_pagination, fn response ->
      put_in(response, ["data", "organization", "projectV2", "items", "pageInfo"], %{
        "hasNextPage" => true,
        "endCursor" => nil
      })
    end)

    repeated_cursor_request = fn _, _, _, _, _ ->
      response =
        project_response()
        |> put_in(["data", "organization", "projectV2", "items", "nodes"], [])
        |> put_in(["data", "organization", "projectV2", "items", "pageInfo"], %{
          "hasNextPage" => true,
          "endCursor" => "same"
        })

      {:ok, %{status: 200, body: response}}
    end

    assert {:error, :github_project_repeated_cursor} =
             GitHubProject.fetch(settings, repeated_cursor_request, {:states, ["Ready"]})
  end

  test "github_api preserves REST status and body while rejecting unsafe arguments" do
    test_pid = self()
    tracker_settings = tracker_settings()

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{
          "method" => "post",
          "path" => " /repos/octo/repo/issues/42/comments ",
          "params" => %{"per_page" => 10},
          "body" => %{"body" => "hello"}
        },
        tracker_settings: tracker_settings,
        github_client: fn method, path, params, body, opts ->
          send(test_pid, {:github_tool_called, method, path, params, body, opts})
          {:ok, %{status: 201, body: %{"id" => 9}}}
        end
      )

    assert_received {:github_tool_called, "POST", "/repos/octo/repo/issues/42/comments", %{"per_page" => 10}, %{"body" => "hello"}, [tracker_settings: ^tracker_settings]}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"status" => 201, "body" => %{"id" => 9}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]

    failure =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/repos/octo/repo/issues/404"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
        end
      )

    assert failure["success"] == false

    assert Jason.decode!(failure["output"]) == %{
             "status" => 404,
             "body" => %{"message" => "Not Found"}
           }

    Enum.each(
      [
        %{"method" => "GET", "path" => "https://api.github.com/user"},
        %{"method" => "GET", "path" => "/user", "params" => false},
        %{"path" => "/user"}
      ],
      fn arguments ->
        invalid =
          GitHubAgentTool.execute(
            "github_api",
            arguments,
            github_client: fn _method, _path, _params, _body, _opts ->
              flunk("invalid github_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )
  end

  test "github_api reports unsupported tools, malformed calls, and client failures" do
    unsupported = GitHubAgentTool.execute("not_github_api", %{}, [])
    assert unsupported["success"] == false
    assert Jason.decode!(unsupported["output"])["error"]["supportedTools"] == ["github_api"]

    Enum.each(
      [
        "not-an-object",
        %{"method" => "GET", "path" => 123}
      ],
      fn arguments ->
        invalid =
          GitHubAgentTool.execute(
            "github_api",
            arguments,
            github_client: fn _method, _path, _params, _body, _opts ->
              flunk("malformed github_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )

    malformed_response =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: "not-an-integer", body: %{}}}
        end
      )

    assert malformed_response["success"] == false

    Enum.each(
      [
        :missing_github_token,
        {:github_api_request, :timeout},
        :unexpected_failure
      ],
      fn reason ->
        failure =
          GitHubAgentTool.execute(
            "github_api",
            %{"method" => "GET", "path" => "/user"},
            github_client: fn _method, _path, _params, _body, _opts ->
              {:error, reason}
            end
          )

        assert failure["success"] == false
        assert %{"error" => %{"message" => message}} = Jason.decode!(failure["output"])
        assert is_binary(message)
      end
    )

    non_json_body =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: 200, body: self()}}
        end
      )

    assert non_json_body["success"]
    assert non_json_body["output"] =~ "#PID"
  end

  test "tracker binds GitHub tools and token env names from provider config" do
    token_env = "SYMPHONY_GITHUB_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_env)
    System.put_env(token_env, "test-token")

    on_exit(fn -> restore_env(token_env, previous_token) end)

    write_github_workflow!(Workflow.workflow_file_path(), "$#{token_env}")

    binding = Tracker.bind_agent_tools()

    assert binding.adapter == GitHubAdapter

    assert binding.secret_environment_names == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN",
             token_env
           ]

    assert [%{"name" => "github_api"}] = binding.tool_specs
    assert :ok = Config.validate!()
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "github",
      provider:
        Map.merge(
          %{
            "repo" => "octo/repo",
            "token" => "test-token"
          },
          provider_overrides
        ),
      active_states: ["open"],
      terminal_states: ["closed"]
    }
  end

  defp project_tracker_settings do
    %{
      kind: "github",
      provider: %{
        "repo" => "signapse-group/signapse",
        "token" => "test-token",
        "project_owner" => "signapse-group",
        "project_number" => 1,
        "issue_types" => ["Task"]
      },
      dispatch_states: ["Ready"],
      active_states: ["Ready", "In progress"],
      review_state: "In review",
      terminal_states: ["Done"]
    }
  end

  defp project_response do
    %{
      "data" => %{
        "organization" => %{
          "projectV2" => %{
            "id" => "PVT_project",
            "field" => %{
              "id" => "PVTSSF_status",
              "options" => [
                %{"id" => "open", "name" => "Open"},
                %{"id" => "ready", "name" => "Ready"},
                %{"id" => "active", "name" => "In progress"},
                %{"id" => "review", "name" => "In review"},
                %{"id" => "blocked", "name" => "Blocked"},
                %{"id" => "done", "name" => "Done"}
              ]
            },
            "items" => %{
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
              "nodes" => [
                project_item(1, "Task", "Ready"),
                project_item(2, "Task", "In progress"),
                project_item(3, "Bug", "Ready")
              ]
            }
          }
        }
      }
    }
  end

  defp project_item(number, type, status) do
    %{
      "id" => "PVTI_#{number}",
      "isArchived" => false,
      "fieldValueByName" => %{"name" => status, "optionId" => String.downcase(status)},
      "content" => %{
        "__typename" => "Issue",
        "id" => "I_#{number}",
        "number" => number,
        "title" => "Project issue #{number}",
        "body" => "Body #{number}",
        "state" => "OPEN",
        "url" => "https://github.test/signapse-group/signapse/issues/#{number}",
        "createdAt" => "2026-01-01T00:00:00Z",
        "updatedAt" => "2026-01-02T00:00:00Z",
        "repository" => %{"nameWithOwner" => "signapse-group/signapse"},
        "issueType" => %{"name" => type}
      }
    }
  end

  defp assert_project_error(settings, error, update_response) do
    response = update_response.(project_response())
    request_fun = fn _, _, _, _, _ -> {:ok, %{status: 200, body: response}} end
    assert {:error, ^error} = GitHubProject.fetch(settings, request_fun, {:states, ["Ready"]})
  end

  defp raw_issue(number) do
    %{
      "number" => number,
      "id" => 1_000 + number,
      "node_id" => "I_#{number}",
      "title" => "Issue #{number}",
      "body" => "Body #{number}",
      "state" => "open",
      "html_url" => "https://github.test/octo/repo/issues/#{number}",
      "assignee" => %{"login" => "octocat"},
      "labels" => [%{"name" => " Bug "}, %{"name" => "bug"}, %{"name" => "Platform"}],
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }
  end

  defp write_github_workflow!(path, token) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: github
        provider:
          repo: "octo/repo"
          token: #{Jason.encode!(token)}
        active_states: ["open"]
        terminal_states: ["closed"]
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
