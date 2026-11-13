defmodule SymphonyElixir.ProfileObservabilityTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{HttpServer, Profile}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub}

  @endpoint Endpoint
  @ids ~w(fe be qa landing planning)
  @fixture Path.expand("../fixtures/profiles/profiles.json", __DIR__)

  defmodule Runtime do
    use GenServer

    def start_link({profile, role, test}) do
      GenServer.start_link(__MODULE__, {profile, test, :running}, name: Profile.via(profile, role))
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:snapshot, _from, {id, _, _} = state) do
      {:reply, snapshot(id), state}
    end

    def handle_call(:request_refresh, _from, {id, test, _} = state) do
      send(test, {:refresh, id})
      {:reply, %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll"]}, state}
    end

    def handle_call(:status, _from, {id, _, mode} = state), do: {:reply, {:ok, status(id, mode)}, state}

    def handle_call({:pause, _reason, "manual"}, _from, {id, test, _}) do
      send(test, {:pause, id})
      {:reply, {:ok, status(id, :paused)}, {id, test, :paused}}
    end

    def handle_call(:resume, _from, {id, test, _}) do
      send(test, {:resume, id})
      {:reply, {:ok, status(id, :checking_quota)}, {id, test, :checking_quota}}
    end

    defp status(id, mode) do
      %{enabled: true, mode: mode, active_turns: 0, database_error: nil, services: %{id => %{status: :online}}}
    end

    defp snapshot(id) do
      item = %{
        issue_id: "issue-#{id}",
        identifier: String.upcase(id) <> "-123",
        issue_url: "https://example.invalid/#{id}",
        state: "Progress",
        session_id: "session-#{id}",
        started_at: nil,
        last_codex_event: :session_started,
        last_codex_message: "private fixture-secret",
        last_codex_timestamp: nil,
        codex_input_tokens: 1,
        codex_output_tokens: 2,
        codex_total_tokens: 3
      }

      %{
        readiness: if(id == "qa", do: %{ready: false, error: :instructions_missing}, else: %{ready: true, error: nil}),
        admission_error: admission_error(id),
        instructions_revision: "fixture-#{id}",
        running: [item],
        retrying: [],
        waiting: [],
        waiting_updated_at: DateTime.utc_now(),
        codex_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 0},
        rate_limits: %{"private" => "fixture-secret"}
      }
    end

    defp admission_error("fe"), do: :provider_quota_exhausted
    defp admission_error("be"), do: :provider_quota_unavailable
    defp admission_error("landing"), do: {:internal_error, "private fixture-secret"}
    defp admission_error(_id), do: nil
  end

  defmodule Instructions do
    def activate(id, revision) do
      test = Endpoint.config(:instructions_test_pid)
      send(test, {:activate, self(), id, revision})

      receive do
        :finish_activation -> {:ok, %{profile_id: id, revision: revision}}
      end
    end

    def status(_id), do: {:error, :missing}
  end

  setup do
    config = Application.get_env(:symphony_elixir, Endpoint)
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, config) end)

    Application.put_env(
      :symphony_elixir,
      Endpoint,
      Keyword.merge(config, instructions: Instructions, instructions_test_pid: self())
    )

    root = Path.join(System.tmp_dir!(), "symphony-profile-dashboard-#{System.unique_integer([:positive])}")

    env =
      Map.new(
        for id <- @ids,
            {suffix, value} <- [
              {"TOKEN", "#{id}-fixture-token"},
              {"ROOT", Path.join([root, "workspaces", id])},
              {"DB", Path.join([root, "state", "#{id}.sqlite3"])},
              {"HOME", Path.join([root, "codex", id])}
            ] do
          {"#{String.upcase(id)}_#{suffix}", value}
        end
      )

    {:ok, profiles} = Profile.load(@fixture, env)
    start_supervised!({Profile, profiles})

    for id <- @ids, role <- [:orchestrator, :runtime_control] do
      start_supervised!(Supervisor.child_spec({Runtime, {id, role, self()}}, id: {id, role}))
    end

    start_supervised!({HttpServer, mode: :profiles, port: 0})
    :ok
  end

  test "one loopback endpoint serves all profiles and reports partial health without raw data" do
    assert {:ok, {{127, 0, 0, 1}, port}} = Bandit.PhoenixAdapter.server_info(Endpoint, :http)
    assert port > 0
    assert Req.get!("http://127.0.0.1:#{port}/api/v1/state").status == 200

    overview = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert overview["mode"] == "profiles"
    assert overview["health"] == "partial"
    assert Enum.map(overview["profiles"], & &1["profile_id"]) == @ids
    assert Enum.find(overview["profiles"], &(&1["profile_id"] == "qa"))["reason"] == "instructions_missing"

    for {id, cap} <- Enum.zip(@ids, [2, 1, 2, 1, 1]) do
      conn = get(build_conn(), "/api/v1/profiles/#{id}/state")
      payload = json_response(conn, 200)
      assert payload["profile_id"] == id
      assert payload["max_concurrent_agents"] == cap
      assert payload["instructions_revision"] == "fixture-#{id}"
      assert byte_size(payload["workflow_revision"]) == 64
      assert payload["counts"] == %{"running" => 1, "retrying" => 0, "blocked" => 0, "waiting" => 0}
      assert payload["runtime_control"]["services"] == %{id => %{"status" => "online"}}
      assert payload["runtime_control"]["desired_state"] == "running"
      refute response(conn, 200) =~ "fixture-secret"
      refute response(conn, 200) =~ "fixture-token"
    end
  end

  test "issue and refresh routes stay scoped and reject invalid or omitted profile" do
    fe = "/api/v1/profiles/fe"
    issue = json_response(get(build_conn(), fe <> "/issues/FE-123"), 200)
    assert issue["profile_id"] == "fe"
    assert String.ends_with?(issue["workspace"]["path"], "/workspaces/fe/FE-123")
    assert json_response(get(build_conn(), fe <> "/issues/BE-123"), 404)["error"]["code"] == "issue_not_found"

    assert json_response(post(build_conn(), fe <> "/refresh", %{}), 202)["profile_id"] == "fe"
    assert_receive {:refresh, "fe"}
    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 400)["error"]["code"] == "profile_required"
    assert json_response(get(build_conn(), "/api/v1/profiles/unknown/state"), 404)["error"]["code"] == "unknown_profile"
    assert json_response(post(build_conn(), "/api/v1/profiles/unknown/refresh", %{}), 404)["error"]["code"] == "unknown_profile"
    refute_received {:refresh, _}
  end

  test "provider quota hold is scoped, safe, and independent of profile health and desired state" do
    overview = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert Enum.find(overview["profiles"], &(&1["profile_id"] == "fe"))["admission_error"] == "provider_quota_exhausted"

    for {id, reason} <- [{"fe", "provider_quota_exhausted"}, {"be", "provider_quota_unavailable"}, {"landing", nil}] do
      payload = json_response(get(build_conn(), "/api/v1/profiles/#{id}/state"), 200)
      assert payload["admission_error"] == reason
      assert payload["health"] == "healthy"
      assert payload["runtime_control"]["desired_state"] == "running"
    end

    {:ok, view, _html} = live(build_conn(), "/profiles/fe")
    assert has_element?(view, "#admission-quota-status", "Provider quota is exhausted")
    assert has_element?(view, "#waiting-queue h2", "Waiting for provider quota")
    assert has_element?(view, "#profile-health", "Ready")

    view |> element("#tab-be") |> render_click()
    assert has_element?(view, "#admission-quota-status", "Provider quota could not be verified")

    view |> element("#tab-landing") |> render_click()
    refute has_element?(view, "#admission-quota-status")
    assert has_element?(view, "#waiting-queue h2", "Waiting for slots")
  end

  test "tabs link to each profile, reload selects the same profile, and foreign events do not change the tab" do
    {:ok, view, _html} = live(build_conn(), "/profiles/qa")
    assert has_element?(view, "#tab-qa[aria-current=page]", "QA")
    assert has_element?(view, "#profile-health", "Instructions missing")
    assert has_element?(view, "#service-health", "Service partially operational")

    for id <- @ids do
      assert has_element?(view, "#tab-#{id}[href='/profiles/#{id}']")
    end

    view |> element("#tab-be") |> render_click()
    assert_patch(view, "/profiles/be")
    assert has_element?(view, "#tab-be[aria-current=page]", "BE")
    assert has_element?(view, "#profile-panel", "BE-123")
    refute has_element?(view, "#profile-panel", "QA-123")

    assert :ok = ObservabilityPubSub.broadcast_update("qa")
    assert render(view) =~ "BE-123"

    {:ok, reloaded, _html} = live(build_conn(), "/profiles/be")
    assert has_element?(reloaded, "#tab-be[aria-current=page]")
    {:ok, invalid, _html} = live(build_conn(), "/profiles/missing")
    assert has_element?(invalid, "[role=alert]", "Profile not found.")
    refute has_element?(invalid, "#pause-profile")
  end

  test "an activation result belongs to the submitting profile across tab changes" do
    {:ok, view, _html} = live(build_conn(), "/profiles/fe")
    render_submit(element(view, "#activate-fe"), %{"profile" => "fe", "revision" => "v2"})
    assert_receive {:activate, task, "fe", "v2"}

    view |> element("#tab-be") |> render_click()
    assert_patch(view, "/profiles/be")
    send(task, :finish_activation)
    render_async(view)

    assert has_element?(view, "#tab-be[aria-current=page]")
    refute has_element?(view, "#profile-action-result")
    view |> element("#tab-fe") |> render_click()
    assert_patch(view, "/profiles/fe")
    assert has_element?(view, "#profile-action-result", "Workflow revision activated.")
  end

  test "pause is available for an unhealthy profile and resume validates current readiness" do
    {:ok, view, _html} = live(build_conn(), "/profiles/qa")
    render_click(view, "pause_profile", %{"profile" => "fe"})
    refute_received {:pause, _}

    view |> element("#pause-profile") |> render_click()
    assert_receive {:pause, "qa"}
    render_async(view)
    assert has_element?(view, "#resume-profile[disabled]")

    render_click(view, "resume_profile", %{"profile" => "qa"})
    render_async(view)
    refute_received {:resume, _}
    assert has_element?(view, "#profile-action-result", "This profile must be healthy before it can resume.")

    view |> element("#tab-fe") |> render_click()
    view |> element("#pause-profile") |> render_click()
    assert_receive {:pause, "fe"}
    render_async(view)
    view |> element("#resume-profile") |> render_click()
    assert_receive {:resume, "fe"}
    render_async(view)
    assert has_element?(view, "#profile-action-result", "Resume requested. Checking quota.")
  end
end
