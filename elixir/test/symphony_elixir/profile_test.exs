defmodule SymphonyElixir.ProfileTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Profile, WorkflowStore}

  @fixtures Path.expand("../fixtures/profiles", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-profile-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "manifest validates IDs and isolates an invalid entry without losing its control path", %{root: root} do
    path = Path.join(root, "profiles.json")
    File.write!(path, "{")
    assert {:error, :invalid_profiles_json} = Profile.load(path, %{})

    File.write!(path, "{}")
    assert {:error, :invalid_profiles_manifest} = Profile.load(path, %{})

    entries = [%{"id" => "fe"}, %{"id" => "fe"}]
    File.write!(path, Jason.encode!(%{"profiles" => entries}))
    assert {:error, :invalid_or_duplicate_profile_id} = Profile.load(path, %{})

    entries = [
      %{"id" => "fe", "workflow" => "fe.md", "instructions_root" => "instructions/fe", "control_path" => "$FE_DB", "env" => %{"JIRA_API_TOKEN" => "$MISSING"}},
      %{"id" => "be", "control_path" => "relative.sqlite"}
    ]

    File.write!(path, Jason.encode!(%{"profiles" => entries}))
    db = Path.join(root, "fe.sqlite")

    assert {:ok,
            [
              %Profile{id: "fe", control_path: ^db, error: :missing_profile_environment_reference},
              %Profile{id: "be", control_path: nil, error: :invalid_profile_control_path}
            ] = profiles} = Profile.load(path, %{"FE_DB" => db})

    start_supervised!({Profile, profiles})
    assert Profile.ids() == ["fe", "be"]
    assert {:ok, %{control_path: ^db}} = Profile.lookup("fe")
    assert {:error, :missing_profile_environment_reference} = WorkflowStore.snapshot("fe")
    assert {:ok, %{revision: nil, error: :missing_profile_environment_reference, reload_error: nil}} = WorkflowStore.status("fe")
  end

  test "scoped subprocess env clears inherited values and never inherits omitted workspace settings" do
    parent = System.get_env()
    name = if Map.has_key?(parent, "PATH"), do: "PATH", else: parent |> Map.keys() |> hd()
    env = Profile.subprocess_env(%{env: %{"PROFILE_MARKER" => "fe", "JIRA_API_TOKEN" => "fixture-secret"}}, ["JIRA_API_TOKEN"])

    assert Map.new(env)[name] == nil
    assert Map.new(env)["PROFILE_MARKER"] == "fe"
    assert Map.new(env)["JIRA_API_TOKEN"] == nil

    assert {:ok, %{workspace: %{root: nil}}} = Schema.parse(%{}, %{})
    assert {:ok, %{workspace: %{root: nil}}} = Schema.parse(%{"workspace" => %{"root" => "$PATH"}}, %{})
  end

  test "checkout workflow makes the package root optional only for a safe relative path", %{root: root} do
    path = Path.join(root, "profiles.json")
    entry = %{"id" => "planning", "workflow" => "planning.md", "control_path" => Path.join(root, "planning.db"), "env" => %{}}

    for {attributes, expected} <- [
          {%{}, %Profile{id: "planning", control_path: entry["control_path"], error: :invalid_profile_entry}},
          {%{"checkout_workflow" => "../WORKFLOW.md"}, %Profile{id: "planning", control_path: entry["control_path"], error: :invalid_checkout_workflow_path}},
          {%{"checkout_workflow" => nil}, %Profile{id: "planning", control_path: entry["control_path"], error: :invalid_checkout_workflow_path}},
          {%{"checkout_workflow" => "workflow/symphony/WORKFLOW.md"},
           %Profile{id: "planning", instructions_root: nil, checkout_workflow: "workflow/symphony/WORKFLOW.md", workflow_path: Path.join(root, "planning.md"), control_path: entry["control_path"]}}
        ] do
      File.write!(path, Jason.encode!(%{"profiles" => [Map.merge(entry, attributes)]}))
      assert {:ok, [^expected]} = Profile.load(path, %{})
    end

    profile = fixture(root, "planning")
    start_supervised!({Profile, [%{profile | checkout_workflow: "workflow/symphony/WORKFLOW.md", instructions_root: nil}]})
    assert {:error, :checkout_instructions_enabled} = SymphonyElixir.Instructions.pin("planning")
  end

  test "missing workflow recovers independently and an invalid reload retains the last good revision", %{root: root} do
    fe = fixture(root, "fe")
    be = fixture(root, "be", copy?: false)
    start_supervised!({Profile, [fe, be]})
    assert {:ok, original} = WorkflowStore.snapshot("fe")
    assert {:error, :missing_workflow_file} = WorkflowStore.snapshot("be")
    assert {:ok, %{control_path: path}} = Profile.lookup("be")
    assert path == be.control_path

    File.cp!(Path.join(@fixtures, "be.md"), be.workflow_path)
    assert :ok = WorkflowStore.force_reload("be")
    assert {:ok, be_snapshot} = WorkflowStore.snapshot("be")

    File.write!(fe.workflow_path, <<255>>)
    assert {:error, :invalid_workflow_encoding} = WorkflowStore.force_reload("fe")
    assert {:ok, ^original} = WorkflowStore.snapshot("fe")
    assert {:ok, %{error: nil, reload_error: :invalid_workflow_encoding}} = WorkflowStore.status("fe")
    assert {:ok, ^be_snapshot} = WorkflowStore.snapshot("be")

    source = File.read!(Path.join(@fixtures, "fe.md"))
    File.write!(fe.workflow_path, String.replace(source, "max_concurrent_agents: 2", "max_concurrent_agents: 1"))
    assert :ok = WorkflowStore.force_reload("fe")
    assert {:ok, updated} = WorkflowStore.snapshot("fe")
    assert updated.settings.agent.max_concurrent_agents == 1
    assert updated.revision != original.revision
    assert original.settings.agent.max_concurrent_agents == 2
    refute inspect(updated) =~ "fixture-secret"

    moved = Path.join(root, "workspaces/other-fe")
    File.write!(fe.workflow_path, String.replace(source, "$SYMPHONY_WORKSPACE_ROOT", moved))
    assert {:error, :ownership_change_requires_drained_restart} = WorkflowStore.force_reload("fe")
    assert {:ok, ^updated} = WorkflowStore.snapshot("fe")
  end

  test "a restarted store cannot change its reservation while a sibling keeps running", %{root: root} do
    fe = fixture(root, "fe")
    be = fixture(root, "be")
    start_supervised!({Profile, [fe, be]})
    fe_pid = GenServer.whereis(Profile.via("fe", :workflow_store))
    be_pid = GenServer.whereis(Profile.via("be", :workflow_store))

    source = File.read!(fe.workflow_path)
    File.write!(fe.workflow_path, String.replace(source, "$SYMPHONY_WORKSPACE_ROOT", Path.join(root, "moved")))
    ref = Process.monitor(fe_pid)
    Process.exit(fe_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^fe_pid, :killed}

    eventually(fn -> WorkflowStore.snapshot("fe") == {:error, :ownership_change_requires_drained_restart} end)
    assert GenServer.whereis(Profile.via("be", :workflow_store)) == be_pid
    assert {:ok, _snapshot} = WorkflowStore.snapshot("be")
  end

  test "canonical workspace aliases and their children cannot be reserved by a second profile", %{root: root} do
    shared = Path.join(root, "shared")
    alias_path = Path.join(root, "alias")
    File.mkdir_p!(shared)
    File.ln_s!(shared, alias_path)
    fe = fixture(root, "fe", workspace: shared)
    be = fixture(root, "be", workspace: Path.join(alias_path, "nested"))
    start_supervised!({Profile, [fe, be]})

    assert {:ok, %{settings: %{workspace: %{root: ^shared}}}} = WorkflowStore.snapshot("fe")
    assert {:error, :overlapping_workspace_roots} = WorkflowStore.snapshot("be")
  end

  test "a missing workflow cannot share its control database with a ready profile", %{root: root} do
    fe = fixture(root, "fe")
    be = fixture(root, "be", copy?: false)
    start_supervised!({Profile, [fe, %{be | control_path: fe.control_path}]})

    for id <- ["fe", "be"] do
      assert {:ok, %{control_path: nil}} = Profile.lookup(id)
      assert {:error, :overlapping_control_paths} = WorkflowStore.snapshot(id)
    end
  end

  test "a route universe missing another profile's route is rejected", %{root: root} do
    fe = fixture(root, "fe")
    be = fixture(root, "be")
    source = File.read!(be.workflow_path)
    File.write!(be.workflow_path, String.replace(source, "route-frontend, ", ""))
    start_supervised!({Profile, [fe, be]})

    assert {:ok, _snapshot} = WorkflowStore.snapshot("fe")
    assert {:error, :overlapping_assignment_filters} = WorkflowStore.snapshot("be")
    File.write!(be.workflow_path, source)
    assert :ok = WorkflowStore.force_reload("be")
    assert {:ok, _snapshot} = WorkflowStore.snapshot("be")
  end

  defp fixture(root, id, opts \\ []) do
    workflow_path = Path.join(root, "#{id}.md")
    control_path = Path.join([root, "db", "#{id}.sqlite3"])
    if Keyword.get(opts, :copy?, true), do: File.cp!(Path.join(@fixtures, "#{id}.md"), workflow_path)

    %Profile{
      id: id,
      workflow_path: workflow_path,
      instructions_root: Path.join([root, "instructions", id]),
      control_path: control_path,
      env: %{
        "JIRA_BASE_URL" => "https://jira.example.invalid",
        "JIRA_EMAIL" => "#{id}@example.invalid",
        "JIRA_API_TOKEN" => "#{id}-fixture-secret",
        "SYMPHONY_WORKSPACE_ROOT" => Keyword.get(opts, :workspace, Path.join([root, "workspaces", id])),
        "CONTROL_DB" => control_path
      }
    }
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if not predicate.() do
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
