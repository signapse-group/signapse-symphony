defmodule SymphonyElixir.InstructionsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Instructions, Profile, PromptBuilder, Workflow}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker.Issue

  @profiles Path.expand("../fixtures/profiles", __DIR__)
  @ids ~w(fe be qa landing planning)
  @qa_operations ~w(qa-generate qa-execute qa-retest)
  @phases ["Ready", "Progress", "In Review"]

  setup context do
    if root = context[:tmp_dir] do
      start_supervised!({Profile, Enum.map(@ids, &profile(root, &1))})
    end

    :ok
  end

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
  end

  @tag :tmp_dir
  test "rejects unusable files and missing mandatory Review skill before launching a task", %{tmp_dir: workspace} do
    workflow = "WORKFLOW.md"
    settings = %Schema{runtime_control: %{id: "fe"}, tracker: %{review_state: "In Review"}}
    issue = issue("In Review", [])
    assert {:error, :checkout_workflow_missing} = Instructions.checkout_template(workspace, workflow)
    assert {:error, :checkout_workflow_invalid} = Instructions.checkout_template(workspace, "../WORKFLOW.md")

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
    File.mkdir_p!(Path.join(workspace, ".agents/skills"))
    assert {:error, :checkout_skills_invalid} = Instructions.checkout_prompt(workspace, workflow, issue, settings)
    checkout_write(workspace, ".agents/skills/generic/SKILL.md", "# Skill\n")
    assert {:error, :checkout_required_file_missing} = Instructions.checkout_prompt(workspace, workflow, issue, settings)

    skill = Path.join(workspace, ".agents/skills/code-review/SKILL.md")
    File.mkdir_p!(Path.dirname(skill))
    File.ln_s!(Path.join(workspace, "AGENTS.md"), skill)
    assert {:error, :checkout_required_file_invalid} = Instructions.checkout_prompt(workspace, workflow, issue, settings)
    File.rm!(skill)
    checkout_write(workspace, ".agents/skills/code-review/SKILL.md", "# Review\n")
    assert {:ok, %{prompt: prompt}} = Instructions.checkout_prompt(workspace, workflow, issue, settings)
    assert prompt =~ "Task #{issue.identifier}"
    assert {:error, :checkout_head_unavailable} = Instructions.checkout_head(workspace)
    assert {_, 0} = System.cmd("git", ["init", "--quiet", workspace])
    git = ["-C", workspace, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
    assert {_, 0} = System.cmd("git", git ++ ["commit", "--quiet", "--allow-empty", "-m", "Fixture"])
    assert {revision, 0} = System.cmd("git", git ++ ["rev-parse", "HEAD"])
    assert {:ok, String.trim(revision)} == Instructions.checkout_head(workspace)
  end

  defp checkout_write(workspace, relative, content) do
    path = Path.join(workspace, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  @tag :tmp_dir
  test "all profiles render local instructions while selected revisions survive a failed update", %{tmp_dir: root} do
    for id <- @ids do
      package = stage(root, id, "v1")
      assert {:ok, pin} = Instructions.activate(id, "v1")
      assert pin.root == package
      assert {:ok, ^pin} = Instructions.pin(id)
      assert {:ok, %{revision: "v1"}} = Instructions.status(id)
      assert File.read!(Path.join(pin.root, "AGENTS.md")) =~ "Read"
    end

    assert {:ok, qa_v1} = Instructions.pin("qa")
    qa_issue = issue("Progress", ["route-quality-assurance", "qa-retest"])
    assert PromptBuilder.build_prompt(qa_issue, nil, qa_v1) =~ "v1-progress-qa-retest"
    assert File.read!(Path.join(qa_v1.root, "progress-qa-retest.md")) == "# Phase\nRead complete local procedure\n"

    stage(root, "qa", "v2")
    assert {:ok, qa_v2} = Instructions.activate("qa", "v2")
    assert PromptBuilder.build_prompt(qa_issue, 2, qa_v2) =~ "v2-progress-qa-retest"
    assert PromptBuilder.build_prompt(qa_issue, nil, qa_v1) =~ "v1-progress-qa-retest"
    assert File.read!(Path.join(qa_v1.root, "progress-qa-retest.md")) =~ "complete local procedure"

    invalid = stage(root, "qa", "broken")
    File.rm!(Path.join(invalid, "in review-qa-execute.md"))
    assert {:error, :missing_or_unsafe_instruction_file} = Instructions.activate("qa", "broken")
    assert {:ok, ^qa_v2} = Instructions.pin("qa")
    assert {:ok, %{revision: "v1"}} = Instructions.status("fe")

    File.rm!(Path.join(qa_v2.root, "ready-qa-generate.md"))
    assert {:error, :missing_or_unsafe_instruction_file} = Instructions.pin("qa")
    assert {:ok, %{revision: "v2"}} = Instructions.status("qa")
    assert {:ok, _fe_pin} = Instructions.pin("fe")
  end

  @tag :tmp_dir
  test "fails closed on bad identity, anchors, links, file permissions and path escapes", %{tmp_dir: root} do
    assert {:error, :missing_active_instructions} = Instructions.pin("fe")
    assert {:error, :unknown_profile} = Instructions.status("unknown")
    assert {:error, :invalid_instructions_revision} = Instructions.activate("fe", "../other")

    package = stage(root, "fe", "invalid")
    manifest = manifest("fe", "invalid", "WORKFLOW.md")

    for {change, reason} <- [
          {fn -> write(package, "instructions.json", Jason.encode!(%{manifest | profile_id: "qa"})) end, :instructions_identity_mismatch},
          {fn -> write(package, "instructions.json", Jason.encode!(%{manifest | required_files: ["../other"]})) end, :invalid_instructions_manifest},
          {fn -> write(package, "instructions.json", "{") end, :invalid_instructions_manifest},
          {fn -> write(package, "instructions.json", Jason.encode!(manifest)) end, nil},
          {fn -> write(package, "WORKFLOW.md", "") end, :invalid_instructions_workflow},
          {fn -> write(package, "WORKFLOW.md", "{{ undefined }}") end, :instructions_render_failed},
          {fn -> write(package, "WORKFLOW.md", "[Phase](ready.md#wrong)") end, :missing_instruction_anchor},
          {fn -> write(package, "WORKFLOW.md", "[Phase](../other.md)") end, :unsafe_instruction_reference},
          {fn -> write(package, "WORKFLOW.md", "[Phase](file:///tmp/other.md)") end, :unsafe_instruction_reference},
          {fn -> write(package, "WORKFLOW.md", "[Phase](https://raw.githubusercontent.com/org/repo/main/runbook.md)") end, :remote_instruction_reference}
        ] do
      change.()
      if reason, do: assert(Instructions.activate("fe", "invalid") == {:error, reason})
    end

    write(package, "WORKFLOW.md", "[Provenance: upstream](https://github.com/org/repo/blob/main/runbook.md)\nRead [Phase](ready.md#phase).")
    File.chmod!(Path.join(package, "ready.md"), 0o644)
    assert {:error, :writable_instruction_file} = Instructions.activate("fe", "invalid")
    File.rm!(Path.join(package, "ready.md"))
    File.ln_s!(Path.join(package, "AGENTS.md"), Path.join(package, "ready.md"))
    assert {:error, :missing_or_unsafe_instruction_file} = Instructions.activate("fe", "invalid")
    assert {:error, :missing_active_instructions} = Instructions.pin("fe")
  end

  @tag :tmp_dir
  test "local anchors work alongside evidence links and fenced examples", %{tmp_dir: root} do
    package = stage(root, "fe", "references")

    write(package, "WORKFLOW.md", """
    # Release gate
    Read [this section](#release-gate), [notes](notes.md#shared-gate-1), and [ticket](https://tracker.example.invalid).
    Optional contacts: [email](mailto:owner@example.invalid) and [repository](https://github.com/example/repository).
    ```
    [Example only](absent.md)
    ```
    """)

    write(package, "notes.md", "# Shared gate\n\n# Shared gate\n")
    assert {:ok, _pin} = Instructions.activate("fe", "references")

    write(package, "notes.md", <<255>>)
    assert {:error, :invalid_instruction_encoding} = Instructions.pin("fe")

    write(package, "WORKFLOW.md", "[Remote runbook](https://github.com/example/repository/blob/main/WORKFLOW.md)")
    assert {:error, :remote_instruction_reference} = Instructions.pin("fe")
  end

  @tag :tmp_dir
  test "validation refuses symlinked packages, invalid manifest shapes and unusable source revisions", %{tmp_dir: root} do
    package = stage(root, "fe", "valid")
    alias_path = Path.join(Path.dirname(package), "alias")
    File.ln_s!(package, alias_path)

    assert {:error, :unsafe_instructions_package} = Instructions.validate("fe", alias_path)

    source = Path.join(root, "source")
    File.mkdir_p!(source)
    git(source, ["init"])
    File.write!(Path.join(source, "WORKFLOW.md"), "Local workflow")
    git(source, ["add", "WORKFLOW.md"])
    git(source, ["-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture", "commit", "-m", "instructions"])
    revision = git(source, ["rev-parse", "HEAD"])
    File.ln_s!(package, Path.join(Path.dirname(package), revision))
    assert {:error, :unsafe_instructions_package} = Instructions.prepare("fe", revision, source, "WORKFLOW.md", [])

    File.rm!(Path.join(Path.dirname(package), revision))
    File.rm_rf!(Path.join(root, "instructions/fe"))
    File.ln_s!(root, Path.join(root, "instructions/fe"))
    assert {:error, :unsafe_instructions_package} = Instructions.status("fe")

    File.rm!(Path.join(root, "instructions/fe"))
    package = stage(root, "fe", "valid")
    assert {:error, :invalid_instructions_revision} = Instructions.activate("fe", nil)

    manifest = manifest("fe", "valid", "WORKFLOW.md")
    write(package, "instructions.json", Jason.encode!(Map.delete(manifest, :required_files)))
    assert {:error, :invalid_instructions_manifest} = Instructions.validate("fe", package)
    write(package, "instructions.json", Jason.encode!(%{manifest | required_files: [0]}))
    assert {:error, :invalid_instructions_manifest} = Instructions.validate("fe", package)

    assert {:error, :invalid_instructions_git_revision} =
             Instructions.prepare("fe", "missing-instructions-ref", source, "WORKFLOW.md", [])

    previous_path = System.get_env("PATH")
    System.put_env("PATH", root)

    try do
      assert {:error, :invalid_instructions_git_revision} = Instructions.prepare("fe", "HEAD", source, "WORKFLOW.md", [])
    after
      System.put_env("PATH", previous_path)
    end
  end

  @tag :tmp_dir
  test "readiness reports a missing instructions root or unavailable workflow", %{tmp_dir: root} do
    stop_supervised!(Profile)

    invalid_path = Path.join(root, "missing.md")
    fe = %{profile(root, "fe") | instructions_root: nil, error: :invalid_profile_entry}
    be = %{profile(root, "be") | workflow_path: invalid_path}
    start_supervised!({Profile, [fe, be]})

    assert {:error, :missing_instructions_root} = Instructions.status("fe")
    assert {:error, :profile_workflow_unavailable} = Instructions.validate("be", root)
  end

  @tag :tmp_dir
  test "stages the Git revision from a dirty consumer without fetching or mutating it", %{tmp_dir: root} do
    repo = Path.join(root, "source")
    File.mkdir_p!(repo)
    git(repo, ["init", "-b", "task"])
    git(repo, ["remote", "add", "origin", "https://github.invalid/unreachable/source.git"])
    File.write!(Path.join(repo, "AGENTS.md"), "Read [Runbook](phase.md#nhiệm-vụ).\n")
    File.write!(Path.join(repo, "phase.md"), "# Nhiệm vụ\nUse pinned guidance.\n")
    File.write!(Path.join(repo, "WORKFLOW.md"), "Chữ ễ. Read [Phase](phase.md#nhiệm-vụ).\n")
    git(repo, ["add", "."])
    git(repo, ["-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture", "commit", "-m", "instructions"])
    revision = git(repo, ["rev-parse", "HEAD"])
    File.write!(Path.join(repo, "phase.md"), "uncommitted edit\n")
    before = git(repo, ["status", "--short", "--branch"])

    assert {:error, :invalid_instructions_git_revision} = Instructions.prepare("fe", "-bad", repo, "WORKFLOW.md", [])
    assert {:ok, pin} = Instructions.prepare("fe", revision, repo, "WORKFLOW.md", [])
    assert pin.revision == revision
    assert {:error, :instructions_revision_exists} = Instructions.prepare("fe", revision, repo, "WORKFLOW.md", [])
    assert {:ok, ^pin} = Instructions.activate("fe", revision)
    assert PromptBuilder.build_prompt(issue("Ready", ["route-frontend"]), nil, pin) =~ "Chữ ễ"
    assert File.read!(Path.join(pin.root, "phase.md")) == "# Nhiệm vụ\nUse pinned guidance.\n"
    assert File.read!(Path.join(repo, "phase.md")) == "uncommitted edit\n"
    assert git(repo, ["status", "--short", "--branch"]) == before
    assert git(repo, ["rev-parse", "HEAD"]) == revision
  end

  test "legacy workflow parser preserves Unicode lines" do
    body = "Chữ ễ and Nhiệm vụ"
    assert {:ok, %{prompt: ^body}} = Workflow.parse("---\r\n---\r\n" <> body)
  end

  defp issue(state, labels) do
    %Issue{id: "1", identifier: "SIGN-1", title: "Assignment", state: state, labels: labels}
  end

  defp profile(root, id) do
    control = Path.join([root, "state", "#{id}.sqlite3"])

    %Profile{
      id: id,
      workflow_path: Path.join(@profiles, "#{id}.md"),
      instructions_root: Path.join([root, "instructions", id]),
      control_path: control,
      env: %{
        "JIRA_API_TOKEN" => "fixture",
        "JIRA_EMAIL" => "fixture@example.invalid",
        "JIRA_BASE_URL" => "https://jira.example.invalid",
        "SYMPHONY_WORKSPACE_ROOT" => Path.join([root, "workspaces", id]),
        "CONTROL_DB" => control
      }
    }
  end

  defp stage(root, id, revision) do
    package = Path.join([root, "instructions", id, "revisions", revision])
    workflow = if id == "planning", do: "workflow/symphony/WORKFLOW.md", else: "WORKFLOW.md"
    write(package, "instructions.json", Jason.encode!(manifest(id, revision, workflow)))
    write(package, "AGENTS.md", "Read [CONTRIBUTING](CONTRIBUTING.md#guidance).\n")
    write(package, "CONTRIBUTING.md", "# Guidance\nRead before work.\n")
    write(package, workflow, workflow_prompt(package, id, revision))
    package
  end

  defp manifest(id, revision, workflow), do: %{profile_id: id, revision: revision, workflow: workflow, required_files: ["CONTRIBUTING.md"]}

  defp workflow_prompt(package, "planning", revision) do
    write(package, ".agents/skills/planning/SKILL.md", "# Plan locally\n")
    "#{revision}-planned: [Planning skill](../../.agents/skills/planning/SKILL.md#plan-locally)\n"
  end

  defp workflow_prompt(package, id, revision) do
    operations = if id == "qa", do: @qa_operations, else: [nil]

    for phase <- @phases, operation <- operations, into: "" do
      name = Enum.join(Enum.reject([String.downcase(phase), operation], &is_nil/1), "-")
      write(package, name <> ".md", "# Phase\nRead complete local procedure\n")
      condition = if operation, do: " and issue.labels contains \"#{operation}\"", else: ""
      "{% if issue.state == \"#{phase}\"#{condition} %}#{revision}-#{name} [Phase](<#{name}.md#phase>){% endif %}\n"
    end
  end

  defp write(root, relative, content) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    if File.exists?(path), do: File.chmod!(path, 0o644)
    File.write!(path, content)
    File.chmod!(path, 0o444)
  end

  defp git(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end
end
