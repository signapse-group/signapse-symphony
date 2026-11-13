defmodule SymphonyElixir.ProfileBoundariesTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias SymphonyElixir.{AssignmentOwners, Orchestrator, Profile, WorkflowStore}

  @tag :tmp_dir
  test "a grouped profile boots in its real supervision tree and fails closed when the ownership DB is replaced", %{tmp_dir: root} do
    {manifest, profile_entry} = write_manifest(root)
    owners_path = Path.join(root, "owners.sqlite")
    scope = %{base_url: "https://jira.example.invalid", project_key: "SIGN"}
    key = {scope.base_url, scope.project_key, "owned"}
    owner = {"fe", Path.join(root, "workspace")}
    unknown_key = {scope.base_url, scope.project_key, "unclaimed"}

    write_manifest(manifest, profile_entry, owners_path)
    assert {:ok, runtime} = Profile.load_runtime(manifest, %{})
    start_supervised!({Profile, runtime})

    assert {:ok, snapshot} = WorkflowStore.snapshot("fe")
    assert snapshot.settings.workspace.root == elem(owner, 1)
    assert %{readiness: %{ready: false}} = Orchestrator.snapshot(Profile.via("fe", :orchestrator), 1_000)
    assert :ok = AssignmentOwners.ready(scope)
    assert {:ok, nil} = AssignmentOwners.owner(unknown_key)
    assert :ok = AssignmentOwners.claim(key, owner)
    assert {:ok, ^owner} = AssignmentOwners.owner(key)
    assert {:error, :assignment_authority_changed} = AssignmentOwners.ready(%{scope | project_key: "OTHER"})

    File.rename!(owners_path, owners_path <> ".backup")
    assert {:error, :assignment_database_replaced} = AssignmentOwners.owner(key)
    File.write!(owners_path, "")

    assert {:error, :assignment_database_replaced} = AssignmentOwners.ready(scope)
    assert {:error, :assignment_database_replaced} = AssignmentOwners.claim(unknown_key, owner)
  end

  @tag :tmp_dir
  test "an unreadable or invalid owner database cannot be used for admission", %{tmp_dir: root} do
    scope = %{base_url: "https://jira.example.invalid", project_key: "SIGN"}
    assert {:error, :assignment_database_unavailable} = AssignmentOwners.ready(scope)
    blocked = Path.join(root, "file-not-directory")
    File.write!(blocked, "")
    assert {:error, :assignment_database_unavailable} = start_error(start_supervised({AssignmentOwners, path: Path.join(blocked, "owners.sqlite")}))

    corrupt = Path.join(root, "corrupt.sqlite")
    File.write!(corrupt, String.duplicate("This is not SQLite.", 64))
    assert {:error, :assignment_database_unavailable} = start_error(start_supervised({AssignmentOwners, path: corrupt}))
  end

  @tag :tmp_dir
  test "owner store reports a database schema failure instead of treating the issue as unclaimed", %{tmp_dir: root} do
    path = Path.join(root, "owners.sqlite")
    start_supervised!({AssignmentOwners, path: path})
    scope = %{base_url: "https://jira.example.invalid", project_key: "SIGN"}
    key = {scope.base_url, scope.project_key, "pending"}
    owner = {"fe", Path.join(root, "workspace")}

    {:ok, conn} = Sqlite3.open(path)

    try do
      assert :ok = Sqlite3.execute(conn, "DROP TABLE assignment_owners")
    after
      Sqlite3.close(conn)
    end

    assert {:error, :assignment_database_unavailable} = AssignmentOwners.claim(key, owner)
    assert {:error, :assignment_database_unavailable} = AssignmentOwners.owner(key)
    assert {:error, :assignment_database_unavailable} = AssignmentOwners.ready(scope)
    assert {:error, _reason} = AssignmentOwners.foreign_assignments(scope, owner, ["pending"])
  end

  defp start_error({:error, {reason, _child_spec}}), do: {:error, reason}

  @tag :tmp_dir
  test "cache reads remain scoped while the store stops and recovers", %{tmp_dir: root} do
    {manifest, _entry} = write_manifest(root)
    assert {:ok, [profile]} = Profile.load(manifest, %{})
    supervisor = start_supervised!({Profile, [profile]})
    children = Supervisor.which_children(supervisor)
    {:profile_workflow_stores, stores, _, _} = List.keyfind(children, :profile_workflow_stores, 0)
    store_id = {:workflow_store, "fe"}
    assert {:ok, snapshot} = WorkflowStore.snapshot("fe")
    assert :ok = WorkflowStore.force_reload("fe")

    workflow = File.read!(profile.workflow_path)
    updated_workflow = String.replace(workflow, "max_concurrent_agents: 2", "max_concurrent_agents: 1")
    File.write!(profile.workflow_path, updated_workflow)
    store = GenServer.whereis(Profile.via("fe", :workflow_store))
    send(store, :poll)
    _state = :sys.get_state(store)
    assert {:ok, updated} = WorkflowStore.snapshot("fe")
    assert updated.settings.agent.max_concurrent_agents == 1
    assert updated.revision != snapshot.revision

    assert :ok = Supervisor.terminate_child(stores, store_id)
    assert {:error, :profile_store_unavailable} = WorkflowStore.snapshot("fe")
    assert {:error, :profile_store_unavailable} = WorkflowStore.force_reload("fe")
    assert {:ok, _pid} = Supervisor.restart_child(stores, store_id)
    assert {:ok, ^updated} = WorkflowStore.snapshot("fe")
  end

  @tag :tmp_dir
  test "inspection redacts credentials and workflow details", %{tmp_dir: root} do
    {manifest, _entry} = write_manifest(root)
    assert {:ok, [profile]} = Profile.load(manifest, %{})
    start_supervised!({Profile, [profile]})
    assert {:ok, snapshot} = WorkflowStore.snapshot("fe")
    store = GenServer.whereis(Profile.via("fe", :workflow_store))

    for {value, visible} <- [
          {profile, "fe"},
          {snapshot, "fe"},
          {snapshot.settings.tracker, "jira"},
          {:sys.get_state(store), "deployment.md"}
        ] do
      formatted = inspect(value)
      assert formatted =~ visible
      refute formatted =~ "private-fixture-token"
      refute formatted =~ "fe fixture"
    end
  end

  defp write_manifest(root) do
    fixture = Path.expand("../fixtures/profiles/fe.md", __DIR__)
    workflow = Path.join(root, "deployment.md")
    File.cp!(fixture, workflow)
    control = Path.join(root, "state.sqlite")

    entry = %{
      id: "fe",
      workflow: workflow,
      instructions_root: Path.join(root, "instructions"),
      control_path: control,
      env: %{
        "JIRA_BASE_URL" => "https://jira.example.invalid",
        "JIRA_EMAIL" => "fixture@example.invalid",
        "JIRA_API_TOKEN" => "private-fixture-token",
        "SYMPHONY_WORKSPACE_ROOT" => Path.join(root, "workspace"),
        "CONTROL_DB" => control
      }
    }

    path = Path.join(root, "profiles.json")
    write_manifest(path, entry, nil)
    {path, entry}
  end

  defp write_manifest(path, entry, owners) do
    File.write!(path, Jason.encode!(%{profiles: [entry], assignment_owners_path: owners}))
  end
end
