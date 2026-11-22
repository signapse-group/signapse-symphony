defmodule SymphonyElixir.InstructionsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Instructions, Workflow}
  alias SymphonyElixir.Tracker.Issue

  @tag :tmp_dir
  test "checkout renders the issue phase and checks only authored instruction links", %{tmp_dir: workspace} do
    workflow = "workflow/symphony/WORKFLOW.md"

    contents = """
    # Checkout task {{ issue.identifier }}
    {{ issue.description }}
    {% if attempt %}Attempt {{ attempt }}{% endif %}
    {% if issue.state == 'Ready' %}
    [Survey](../../docs/runbooks/survey.md#survey).
    {% else %}
    [Implement](../../docs/runbooks/implement.md).
    {% endif %}
    [Dependency](https://github.com/org/repo/blob/main/docs/contract.md).
    [Evidence](../../docs/results/task.md).
    ~~~markdown
    [Illustrative link](../../docs/runbooks/not-a-real-runbook.md).
    ~~~
    """

    contents = String.replace(contents, "\n", "\r\n")
    checkout_write(workspace, workflow, contents)
    checkout_write(workspace, "AGENTS.md", "# Agents\n")
    checkout_write(workspace, ".agents/skills/generic/SKILL.md", "# Skill\n")
    checkout_write(workspace, "docs/runbooks/survey.md", "# Survey\nRead [standard](../../CONTRIBUTING.md#verification).")
    checkout_write(workspace, "CONTRIBUTING.md", "# Verification\n")
    assert {:ok, settings} = Schema.parse(%{})
    issue = %{issue("Ready", []) | description: "[Injected](../../docs/runbooks/missing.md)"}

    assert {:ok, workflow_data} = Instructions.checkout_prompt(workspace, workflow, issue, settings, 2)
    assert workflow_data.prompt =~ "Attempt 2"
    assert workflow_data.prompt =~ "relative to #{workflow}"
    assert workflow_data.prompt =~ "[Injected]"
    refute workflow_data.prompt =~ "Implement"
    refute workflow_data.prompt =~ "\r"
    assert workflow_data.workflow_digest == Base.encode16(:crypto.hash(:sha256, contents), case: :lower)

    assert {:error, {:checkout_instructions, :checkout_required_file_missing, "docs/runbooks/implement.md"}} =
             Instructions.prepare_checkout(workspace, workflow, %{issue | state: "Progress"}, settings, nil)

    checkout_write(workspace, "CONTRIBUTING.md", "# Invalid anchor\n")

    assert {:error, {:checkout_instructions, :checkout_required_file_invalid, "CONTRIBUTING.md"}} =
             Instructions.prepare_checkout(workspace, workflow, issue, settings, nil)

    checkout_write(workspace, workflow, "[Escape](../../../docs/runbooks/survey.md)")

    assert {:error, :checkout_required_file_invalid} =
             Instructions.checkout_prompt(workspace, workflow, issue, settings)
  end

  @tag :tmp_dir
  test "rejects unusable files and missing mandatory Review skill before launching a task", %{tmp_dir: workspace} do
    workflow = "WORKFLOW.md"
    settings = %Schema{runtime_control: %{id: "fe"}, tracker: %{review_state: "In Review"}}
    issue = issue("In Review", [])
    assert {:error, :checkout_workflow_missing} = Instructions.checkout_template(workspace, workflow)
    assert {:error, :checkout_workflow_invalid} = Instructions.checkout_template(workspace, "../WORKFLOW.md")
    assert {:error, :checkout_workflow_invalid} = Instructions.checkout_template(workspace, nil)

    for content <- [" ", <<255>>, "---\ntracker:\n  kind: attacker\n---\nVisible"] do
      checkout_write(workspace, workflow, content)
      assert {:error, :checkout_workflow_invalid} = Instructions.checkout_template(workspace, workflow)
    end

    checkout_write(workspace, workflow, "{{ unknown }}")
    assert {:error, :checkout_prompt_invalid} = Instructions.checkout_prompt(workspace, workflow, issue, settings)
    checkout_write(workspace, workflow, "Task {{ issue.identifier }}")
    assert {:error, :checkout_agents_missing} = Instructions.checkout_prompt(workspace, workflow, issue, settings)
    checkout_write(workspace, "AGENTS.md", "# Agents\n")
    assert {:error, :checkout_skills_missing} = Instructions.checkout_prompt(workspace, workflow, issue, settings)
    checkout_write(workspace, ".agents/skills", "Not a directory")
    assert {:error, :checkout_skills_invalid} = Instructions.checkout_prompt(workspace, workflow, issue, settings)
    File.rm!(Path.join(workspace, ".agents/skills"))
    File.mkdir_p!(Path.join(workspace, ".agents/skills"))
    assert {:error, :checkout_skills_invalid} = Instructions.checkout_prompt(workspace, workflow, issue, settings)
    checkout_write(workspace, ".agents/skills/generic/SKILL.md", "# Skill\n")

    assert {:error, :checkout_required_file_missing} =
             Instructions.checkout_prompt(workspace, workflow, issue, settings)

    skill = Path.join(workspace, ".agents/skills/code-review/SKILL.md")
    File.mkdir_p!(Path.dirname(skill))
    File.ln_s!(Path.join(workspace, "AGENTS.md"), skill)

    assert {:error, :checkout_required_file_invalid} =
             Instructions.checkout_prompt(workspace, workflow, issue, settings)

    File.rm!(skill)
    checkout_write(workspace, ".agents/skills/code-review/SKILL.md", "# Review\n")
    assert {:ok, %{prompt: prompt}} = Instructions.checkout_prompt(workspace, workflow, issue, settings)
    assert prompt =~ "Task #{issue.identifier}"
    assert {:error, :checkout_head_unavailable} = Instructions.checkout_head(workspace)
    assert {:error, :checkout_head_unavailable} = Instructions.checkout_head(Path.join(workspace, "absent"))
    assert {_, 0} = System.cmd("git", ["init", "--quiet", workspace])
    assert {:error, :checkout_head_unavailable} = Instructions.checkout_head(workspace)
    git = ["-C", workspace, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
    commit = ["commit", "--quiet", "--allow-empty", "-m", "Fixture"]
    assert {_, 0} = System.cmd("git", git ++ commit)
    assert {revision, 0} = System.cmd("git", git ++ ["rev-parse", "HEAD"])
    assert {:ok, String.trim(revision)} == Instructions.checkout_head(workspace)
  end

  defp checkout_write(workspace, relative, content) do
    path = Path.join(workspace, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  @tag :tmp_dir
  test "a new attempt reads the current upstream instructions and preserves the existing task tree", %{tmp_dir: root} do
    repo = Path.join(root, "published")
    workspace = Path.join(root, "existing-task")
    assert {_, 0} = System.cmd("git", ["init", "--quiet", "--initial-branch=main", repo])
    checkout_write(repo, "WORKFLOW.md", "Original {{ issue.identifier }}")
    checkout_write(repo, "AGENTS.md", "# Original instructions")
    checkout_write(repo, ".agents/skills/example/SKILL.md", "# Original skill")
    checkout_write(repo, "src/unrelated.bin", "Never materialize product files as instructions")
    original = commit_checkout!(repo)
    assert {_, 0} = System.cmd("git", ["clone", "--quiet", repo, workspace])
    assert {_, 0} = System.cmd("git", ["-C", workspace, "switch", "--quiet", "-c", "codex/issue"])
    checkout_write(workspace, "AGENTS.md", "# Unsaved task change")
    checkout_write(workspace, "artifacts/run.json", "{}")

    assert {:ok, settings} = Schema.parse(%{})

    snapshot = %{
      checkout_workflow: "WORKFLOW.md",
      checkout_upstream: %{repository: "file://#{repo}", branch: "main"},
      settings: settings,
      env: Map.take(System.get_env(), ["PATH", "HOME"])
    }

    assert ^original = Instructions.with_checkout_upstream(snapshot, nil, & &1.revision)

    checkout_write(repo, "WORKFLOW.md", "Fresh {{ issue.identifier }} from [Implement](docs/runbooks/implement.md).")
    checkout_write(repo, "docs/runbooks/implement.md", "# Current implementation procedure")
    checkout_write(repo, "AGENTS.md", "# Published instructions")
    checkout_write(repo, ".agents/skills/example/SKILL.md", "# Published skill")
    checkout_write(repo, "scripts/validate-qa-handoff.mjs", "// Published handoff checker")
    updated = commit_checkout!(repo)
    refute updated == original

    source_root =
      Instructions.with_checkout_upstream(snapshot, nil, fn source ->
        assert source.revision == updated
        assert {:ok, %{prompt: prompt, source: ^source}} = Instructions.prepare_checkout(source.root, "WORKFLOW.md", issue("Progress", []), settings, 2, source)
        assert prompt =~ "Fresh SIGN-1"
        assert prompt =~ Path.join(source.root, "AGENTS.md")
        assert File.read!(Path.join(source.root, "AGENTS.md")) == "# Published instructions"
        assert File.read!(Path.join(source.root, ".agents/skills/example/SKILL.md")) == "# Published skill"
        assert File.exists?(Path.join(source.root, "scripts/validate-qa-handoff.mjs"))
        refute File.exists?(Path.join(source.root, "src/unrelated.bin"))
        source.root
      end)

    refute File.exists?(source_root)
    assert {:ok, ^original} = Instructions.checkout_head(workspace)
    assert {"codex/issue\n", 0} == System.cmd("git", ["-C", workspace, "branch", "--show-current"])
    assert File.read!(Path.join(workspace, "AGENTS.md")) == "# Unsaved task change"
    assert File.read!(Path.join(workspace, "artifacts/run.json")) == "{}"
    assert File.read!(Path.join(workspace, "WORKFLOW.md")) == "Original {{ issue.identifier }}"

    missing = put_in(snapshot.checkout_upstream.branch, "dev")

    assert {:error, {:checkout_instructions, :checkout_upstream_unavailable, "WORKFLOW.md"}} =
             Instructions.with_checkout_upstream(missing, nil, fn _ -> flunk("Started without a fresh instructions source") end)

    assert {:error, {:checkout_instructions, :checkout_upstream_unavailable, "WORKFLOW.md"}} =
             Instructions.with_checkout_upstream(snapshot, "remote.example.invalid", fn _ -> flunk("Opened a local pin on a remote worker") end)

    for authorization <- [%{"SYMPHONY_GIT_CREDENTIAL_HELPER" => "fixture-helper"}, %{"GITHUB_TOKEN" => "fixture-token"}] do
      authorized = %{snapshot | env: Map.merge(snapshot.env, authorization)}
      assert ^updated = Instructions.with_checkout_upstream(authorized, nil, & &1.revision)
    end

    path = System.fetch_env!("PATH")

    try do
      System.put_env("PATH", root)

      assert {:error, {:checkout_instructions, :checkout_upstream_unavailable, "WORKFLOW.md"}} =
               Instructions.with_checkout_upstream(snapshot, nil, fn _ -> flunk("Started without the clone timeout program") end)
    after
      System.put_env("PATH", path)
    end

    assert_raise RuntimeError, "fixture callback failed", fn ->
      Instructions.with_checkout_upstream(snapshot, nil, fn source ->
        send(self(), {:failed_source, source.root})
        raise "fixture callback failed"
      end)
    end

    assert_receive {:failed_source, failed_source}
    refute File.exists?(failed_source)

    assert catch_exit(
             Instructions.with_checkout_upstream(snapshot, nil, fn source ->
               send(self(), {:held_source, source.root})
               exit({:session_stop_unconfirmed, :fixture})
             end)
           ) == {:session_stop_unconfirmed, :fixture}

    assert_receive {:held_source, held_source}
    on_exit(fn -> File.rm_rf!(Path.dirname(held_source)) end)
    assert File.exists?(Path.join(held_source, "AGENTS.md"))
  end

  defp commit_checkout!(repo) do
    git = ["-C", repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
    assert {_, 0} = System.cmd("git", git ++ ["add", "."])
    assert {_, 0} = System.cmd("git", git ++ ["commit", "--quiet", "-m", "Publish fixture"])
    assert {:ok, revision} = Instructions.checkout_head(repo)
    revision
  end

  test "legacy workflow parser preserves Unicode lines" do
    body = "Chữ ễ and Nhiệm vụ"
    assert {:ok, %{prompt: ^body}} = Workflow.parse("---\r\n---\r\n" <> body)
  end

  defp issue(state, labels) do
    %Issue{id: "1", identifier: "SIGN-1", title: "Assignment", state: state, labels: labels}
  end
end
