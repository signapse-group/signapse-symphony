defmodule SymphonyElixir.ProfileManifestTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Profile, WorkflowStore}

  @fixture_dir Path.expand("../fixtures/profiles", __DIR__)
  @profiles [
    {"fe", "route-frontend", 2},
    {"be", "route-backend", 1},
    {"qa", "route-quality-assurance", 2},
    {"landing", "route-landing", 1},
    {"planning", nil, 1}
  ]

  @tag :tmp_dir
  test "runtime requires a durable owners database separate from profile control paths", %{tmp_dir: root} do
    manifest = Path.join(root, "profiles.json")
    control = Path.join(root, "fe.sqlite3")
    owners = Path.join(root, "owners.sqlite3")
    input = %{"profiles" => [%{"id" => "fe", "workflow" => "fe.md", "control_path" => control, "instructions_root" => "instructions", "env" => %{}}]}

    File.write!(manifest, Jason.encode!(input))
    assert {:error, :invalid_assignment_owners_path} = Profile.load_runtime(manifest, %{})

    File.write!(manifest, Jason.encode!(Map.put(input, "assignment_owners_path", control)))
    assert {:error, :overlapping_assignment_owners_path} = Profile.load_runtime(manifest, %{})

    File.write!(manifest, Jason.encode!(Map.put(input, "assignment_owners_path", "$OWNERS_DB")))
    assert {:ok, {[%{id: "fe", control_path: ^control}], ^owners}} = Profile.load_runtime(manifest, %{"OWNERS_DB" => owners})
  end

  test "five profiles retain independent settings in concurrent callbacks" do
    root = Path.join(System.tmp_dir!(), "symphony-profiles-#{System.unique_integer([:positive])}")

    host_env =
      Map.new(
        for {id, _, _} <- @profiles,
            {suffix, value} <- [
              {"TOKEN", "#{id}-fixture-token"},
              {"ROOT", Path.join([root, "workspaces", id])},
              {"DB", Path.join([root, "state", "#{id}.sqlite3"])},
              {"HOME", Path.join([root, "codex", id])}
            ] do
          {"#{String.upcase(id)}_#{suffix}", value}
        end
      )

    assert {:ok, profiles} = Profile.load(Path.join(@fixture_dir, "profiles.json"), host_env)
    start_supervised!({Profile, profiles})

    tasks =
      for {id, route, cap} <- @profiles do
        Task.async(fn ->
          assert {:ok, snapshot} = WorkflowStore.snapshot(id)
          assert snapshot.profile_id == id
          assert snapshot.workflow_path == Path.join(@fixture_dir, "#{id}.md")
          assert snapshot.settings.workspace.root == Path.join([root, "workspaces", id])
          assert snapshot.settings.runtime_control.id == id
          assert snapshot.settings.runtime_control.members == [id]
          assert snapshot.settings.runtime_control.path == Path.join([root, "state", "#{id}.sqlite3"])
          assert snapshot.settings.agent.max_concurrent_agents == cap
          assert snapshot.settings.tracker.required_labels == if(route, do: [route], else: [])
          assert snapshot.settings.tracker.dispatch_states == if(route, do: ["Ready", "Progress", "In Review"], else: ["Planned"])
          assert snapshot.env["JIRA_API_TOKEN"] == "#{id}-fixture-token"
          assert snapshot.env["CODEX_HOME"] == Path.join([root, "codex", id])
          assert {:ok, %{revision: revision, error: nil, reload_error: nil}} = WorkflowStore.status(id)
          assert revision == snapshot.revision
          revision
        end)
      end

    assert tasks |> Task.await_many() |> Enum.uniq() |> length() == length(@profiles)
    assert {:error, _reason} = WorkflowStore.snapshot("unconfigured")
  end
end
