defmodule SymphonyElixir.ProfileWorkspaceTest do
  use ExUnit.Case, async: false

  import SymphonyElixir.TestSupport, only: [instructions_probe_root: 1, mount_instruction_fixture: 2]

  alias SymphonyElixir.Workspace

  @tag :tmp_dir
  test "a contained hook cannot write its pin and its background subprocess is stopped", %{tmp_dir: root} do
    if System.get_env("SYMPHONY_TEST_SYSTEMD") == "1" do
      root = instructions_probe_root(root)
      base = snapshot(root, "qa")
      File.mkdir_p!(base.instructions.root)
      File.write!(Path.join(base.instructions.root, "policy"), "pinned")
      mount_instruction_fixture(root, base.instructions.root)
      env = Map.merge(base.env, Map.take(System.get_env(), ~w(PATH HOME XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS)))
      recipient = self()

      script = """
      test -r "$SYMPHONY_INSTRUCTIONS_ROOT/policy" || exit 5
      if touch "$SYMPHONY_INSTRUCTIONS_ROOT/should-not-exist"; then exit 6; fi
      sleep 30 &
      printf '%s' "$!" > child.pid
      """

      snapshot =
        base
        |> Map.put(:env, env)
        |> put_in([:settings, :codex], %{read_timeout_ms: 5_000})
        |> put_in([:settings, :tracker, :kind], "jira")
        |> put_in([:settings, :hooks, :before_run], script)
        |> Map.put(:hook_started, fn session ->
          send(recipient, {:registered, session.containment})
          :ok
        end)
        |> Map.put(:hook_stopped, fn ->
          send(recipient, :stopped)
          :ok
        end)

      assert {:ok, workspace} = Workspace.create_for_issue("SIGN-5", nil, snapshot)
      assert :ok = Workspace.run_before_run_hook(workspace, "SIGN-5", nil, snapshot)
      assert_receive {:registered, %{invocation: nil}}
      assert_receive {:registered, %{invocation: invocation}} when is_binary(invocation)
      assert_receive :stopped
      refute File.exists?(Path.join(snapshot.instructions.root, "should-not-exist"))
      pid = File.read!(Path.join(workspace, "child.pid"))

      case File.read("/proc/#{pid}/stat") do
        {:error, :enoent} -> :ok
        {:ok, stat} -> assert stat =~ ~r/\) Z /
      end
    end
  end

  @tag :tmp_dir
  test "isolated hooks see only their profile environment and pin in the assignment workspace", %{tmp_dir: root} do
    original = System.get_env("SYMPHONY_WORKSPACE_TEST_GLOBAL")
    System.put_env("SYMPHONY_WORKSPACE_TEST_GLOBAL", "global")
    on_exit(fn -> restore_env(original) end)

    snapshots = for id <- ["fe", "qa"], do: snapshot(root, id)

    assert [fe, qa] =
             snapshots
             |> Task.async_stream(fn snapshot ->
               assert {:ok, workspace} = Workspace.create_for_issue("SIGN-1", nil, snapshot)
               assert :ok = Workspace.run_before_run_hook(workspace, "SIGN-1", nil, snapshot)
               assert :ok = Workspace.run_after_run_hook(workspace, "SIGN-1", nil, snapshot)
               workspace
             end)
             |> Enum.map(fn {:ok, workspace} -> workspace end)

    refute fe == qa
    assert File.read!(Path.join(fe, "context")) == "fe|#{root}/fe-instructions|v1|"
    assert File.read!(Path.join(qa, "context")) == "qa|#{root}/qa-instructions|v1|"
    assert File.read!(Path.join(qa, "output")) == "output"

    [fe_snapshot, qa_snapshot] = snapshots
    assert {:error, {:workspace_outside_root, _, _}, _} = Workspace.remove_recorded(qa, nil, fe_snapshot)
    assert {:error, {:workspace_equals_root, _, _}, _} = Workspace.remove_recorded(fe_snapshot.settings.workspace.root, nil, fe_snapshot)
    assert {:error, :profile_remote_workspace_unsupported} = Workspace.create_for_issue("SIGN-1", "remote", fe_snapshot)
    assert {:ok, _paths} = Workspace.remove_recorded(fe, nil, fe_snapshot)
    refute File.exists?(fe)

    refusing = put_in(qa_snapshot.settings.hooks.before_remove, "exit 1")
    assert {:error, {:workspace_hook_failed, "before_remove", 1, _}, _} = Workspace.remove_issue_workspaces("SIGN-1", nil, refusing)
    assert File.read!(Path.join(qa, "output")) == "output"
    assert :ok = Workspace.remove_issue_workspaces("SIGN-1", nil, qa_snapshot)
  end

  defp restore_env(nil), do: System.delete_env("SYMPHONY_WORKSPACE_TEST_GLOBAL")
  defp restore_env(value), do: System.put_env("SYMPHONY_WORKSPACE_TEST_GLOBAL", value)

  defp snapshot(root, id) do
    %{
      profile_id: id,
      env: %{"PROFILE_MARKER" => id, "JIRA_API_TOKEN" => "secret"},
      instructions: %{root: Path.join(root, "#{id}-instructions"), revision: "v1"},
      settings: %{
        workspace: %{root: Path.join(root, id)},
        tracker: %{provider: %{}},
        hooks: %{
          timeout_ms: 5_000,
          after_create: "printf '%s' output > output",
          before_run:
            "test -z \"${SYMPHONY_WORKSPACE_TEST_GLOBAL+x}${JIRA_API_TOKEN+x}\" && " <>
              "printf '%s|%s|%s|' \"$PROFILE_MARKER\" \"$SYMPHONY_INSTRUCTIONS_ROOT\" \"$SYMPHONY_INSTRUCTIONS_REVISION\" > context",
          after_run: nil,
          before_remove: nil
        }
      }
    }
  end
end
