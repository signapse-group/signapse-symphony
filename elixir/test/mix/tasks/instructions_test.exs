defmodule Mix.Tasks.InstructionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Instructions.{Prepare, Validate}
  alias SymphonyElixir.Profile

  @manifest_env "SYMPHONY_PROFILES"

  @tag :tmp_dir
  test "the operator tasks stage and validate a local commit without activating it", %{tmp_dir: root} do
    fixture = Path.expand("../../fixtures/profiles/fe.md", __DIR__)
    workflow = Path.join(root, "deployment.md")
    File.cp!(fixture, workflow)
    File.write!(Path.join(root, "AGENTS.md"), "# Agent instructions\nRead this revision.\n")
    File.write!(Path.join(root, "WORKFLOW.md"), "Follow [local instructions](AGENTS.md#agent-instructions).\n")
    git(root, ["init", "-q"])
    git(root, ["add", "AGENTS.md", "WORKFLOW.md"])
    git(root, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Instructions"])
    revision = git(root, ["rev-parse", "HEAD"])
    manifest = Path.join(root, "profiles.json")
    instructions_root = Path.join(root, "instructions")
    control_path = Path.join(root, "state.sqlite")
    workspace = Path.join(root, "workspaces")

    File.write!(
      manifest,
      Jason.encode!(%{
        profiles: [
          %{
            id: "fe",
            workflow: workflow,
            instructions_root: instructions_root,
            control_path: control_path,
            env: %{
              "JIRA_BASE_URL" => "https://jira.example.invalid",
              "JIRA_EMAIL" => "fixture@example.invalid",
              "JIRA_API_TOKEN" => "fixture",
              "SYMPHONY_WORKSPACE_ROOT" => workspace,
              "CONTROL_DB" => control_path
            }
          }
        ]
      })
    )

    with_manifest(manifest)

    assert capture_io(fn -> Prepare.run(["fe", revision, root, "WORKFLOW.md"]) end) =~ "Validated fe revision #{revision}"
    assert Profile.ids() == []
    refute File.exists?(Path.join(instructions_root, "active"))

    package = Path.join([instructions_root, "revisions", revision])
    assert capture_io(fn -> Validate.run(["fe", package]) end) =~ "Validated fe revision #{revision}"
    assert Profile.ids() == []

    File.rm!(Path.join(package, "AGENTS.md"))
    assert_raise Mix.Error, ~r/missing_or_unsafe_instruction_file/, fn -> Validate.run(["fe", package]) end
    assert Profile.ids() == []
  end

  @tag :tmp_dir
  test "the operator tasks give usage and manifest errors", %{tmp_dir: root} do
    assert_raise Mix.Error, ~r/Usage: mix instructions.prepare/, fn -> Prepare.run([]) end
    assert_raise Mix.Error, ~r/Usage: mix instructions.validate/, fn -> Validate.run([]) end

    with_manifest(nil)
    assert_raise Mix.Error, ~r/Set SYMPHONY_PROFILES/, fn -> Validate.run(["fe", root]) end
    System.put_env(@manifest_env, Path.join(root, "missing.json"))
    assert_raise Mix.Error, ~r/Could not start profile configuration/, fn -> Validate.run(["fe", root]) end
  end

  defp with_manifest(path) do
    previous = System.get_env(@manifest_env)
    on_exit(fn -> set_manifest(previous) end)
    set_manifest(path)
  end

  defp set_manifest(nil), do: System.delete_env(@manifest_env)
  defp set_manifest(path), do: System.put_env(@manifest_env, path)

  defp git(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(output)
  end
end
