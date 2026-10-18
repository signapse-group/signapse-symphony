defmodule SymphonyElixir.WorkflowUpdateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.WorkflowUpdate

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    seed = Path.join(root, "seed")
    checkout = Path.join(root, "checkout")
    remote = Path.join(root, "remote.git")
    File.mkdir_p!(seed)
    git(root, ["init", "--bare", "--initial-branch=main", remote])
    git(seed, ["init", "--initial-branch=main"])
    git(seed, ["config", "user.email", "test@example.invalid"])
    git(seed, ["config", "user.name", "Test"])
    write_workflow_file!(Path.join(seed, "WORKFLOW.md"), tracker_kind: "memory", poll_interval_ms: 600_000)
    git(seed, ["add", "."])
    git(seed, ["commit", "-m", "Initial workflow"])
    git(seed, ["remote", "add", "origin", remote])
    git(seed, ["push", "origin", "main"])
    git(root, ["clone", remote, checkout])
    Workflow.set_workflow_file_path(Path.join(checkout, "WORKFLOW.md"))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    server = start_supervised!({Orchestrator, name: __MODULE__.Orchestrator})
    before = git(checkout, ["rev-parse", "HEAD"])
    %{root: root, seed: seed, checkout: checkout, remote: remote, server: server, before: before}
  end

  test "updates only the configured repository and reloads without restarting", context do
    %{checkout: checkout, server: server, root: root} = context
    issue_clone = Path.join(root, "existing-issue")
    File.mkdir_p!(issue_clone)
    File.write!(Path.join(issue_clone, "AGENTS.md"), "Keep my instructions")
    store = Process.whereis(WorkflowStore)
    revision = publish(context, prompt: "New workflow {{ issue.identifier }}", max_turns: 7)

    assert {:ok, message} = WorkflowUpdate.update(server)
    assert message =~ String.slice(revision, 0, 8)
    assert git(checkout, ["rev-parse", "HEAD"]) == revision
    assert {:ok, %{prompt: "New workflow {{ issue.identifier }}"}} = Workflow.current()
    assert Config.settings!().agent.max_turns == 7
    assert Process.whereis(WorkflowStore) == store
    assert Process.alive?(server)
    assert File.read!(Path.join(issue_clone, "AGENTS.md")) == "Keep my instructions"
    assert {:ok, message} = WorkflowUpdate.update(server)
    assert message =~ "already up to date"
  end

  test "missing workflow references refuse activation and tracked runbooks are accepted", context do
    publish(context, prompt: "Read [runbook](<docs/runbooks/survey.md#gate>).")
    assert {:error, message} = WorkflowUpdate.update(context.server)
    assert message =~ "reference is missing"
    assert git(context.checkout, ["rev-parse", "HEAD"]) == context.before

    path = Path.join(context.seed, "docs/runbooks/survey.md")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# Gate\nRead the accepted contract.\n")
    commit_and_push(context.seed)
    assert {:ok, _} = WorkflowUpdate.update(context.server)
    assert File.read!(Path.join(context.checkout, "docs/runbooks/survey.md")) =~ "# Gate"

    script = Path.join(context.seed, "check.sh")
    File.write!(script, "#!/bin/sh\nexit 0\n")
    File.chmod!(script, 0o755)
    publish(context, prompt: "Read [runbook](docs/runbooks/survey.md) and [check](check.sh); [external](https://example.invalid) [section](#gate).")
    assert {:ok, _} = WorkflowUpdate.update(context.server)
  end

  test "busy runtime refuses before fetching and again before applying", context do
    %{server: server, checkout: checkout, before: before} = context
    publish(context, prompt: "New prompt")
    :sys.replace_state(server, &%{&1 | running: %{"busy" => %{}}})
    on_exit(fn -> if Process.alive?(server), do: :sys.replace_state(server, &%{&1 | running: %{}}) end)
    assert {:error, message} = WorkflowUpdate.update(server)
    assert message =~ "busy"
    assert {:error, ^message} = GenServer.call(server, {:apply_workflow_update, %{}})
    refute File.exists?(Path.join(checkout, ".git/FETCH_HEAD"))
    assert git(checkout, ["rev-parse", "HEAD"]) == before
  end

  test "dirty or non-main checkouts are preserved", context do
    %{server: server, checkout: checkout, before: before} = context
    publish(context, prompt: "New prompt")
    File.write!(Path.join(checkout, "notes.txt"), "Uncommitted work")
    assert {:error, message} = WorkflowUpdate.update(server)
    assert message =~ "no local changes"
    assert File.read!(Path.join(checkout, "notes.txt")) == "Uncommitted work"
    File.rm!(Path.join(checkout, "notes.txt"))
    git(checkout, ["switch", "-c", "contribution"])
    assert {:error, ^message} = WorkflowUpdate.update(server)
    assert git(checkout, ["rev-parse", "HEAD"]) == before
  end

  test "restart-required configuration and unknown options are rejected", context do
    for options <- [[server_port: 4567], [workspace_root: "/different-root"], [tracker_active_states: ["Different"]]] do
      publish(context, options)
      assert {:error, message} = WorkflowUpdate.update(context.server)
      assert message =~ "reviewed deployment"
      assert git(context.checkout, ["rev-parse", "HEAD"]) == context.before
    end

    publish(context, prompt: "New prompt")
    path = Path.join(context.seed, "WORKFLOW.md")
    File.write!(path, String.replace(File.read!(path), "agent:\n", "agent:\n  future_engine_option: true\n"))
    commit_and_push(context.seed)
    assert {:error, message} = WorkflowUpdate.update(context.server)
    assert message =~ "reviewed deployment"
  end

  test "invalid schema, YAML and Liquid leave the current workflow in place", context do
    for options <- [[max_turns: 0], [prompt: "{% if %}"]] do
      publish(context, options)
      assert {:error, message} = WorkflowUpdate.update(context.server)
      assert message =~ "invalid"
      assert git(context.checkout, ["rev-parse", "HEAD"]) == context.before
    end

    File.write!(Path.join(context.seed, "WORKFLOW.md"), "---\ntracker: [\n---\nBad")
    commit_and_push(context.seed)
    assert {:error, message} = WorkflowUpdate.update(context.server)
    assert message =~ "invalid"
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()
  end

  test "candidate symlink and missing workflow are rejected", context do
    path = Path.join(context.seed, "WORKFLOW.md")
    File.rm!(path)
    File.ln_s!("elsewhere.md", path)
    commit_and_push(context.seed)
    assert {:error, message} = WorkflowUpdate.update(context.server)
    assert message =~ "regular tracked file"
    File.rm!(path)
    commit_and_push(context.seed)
    assert {:error, ^message} = WorkflowUpdate.update(context.server)
    assert git(context.checkout, ["rev-parse", "HEAD"]) == context.before
  end

  test "remote failure and divergent history never reset local main", context do
    git(context.checkout, ["remote", "set-url", "origin", Path.join(context.root, "absent.git")])
    assert {:error, message} = WorkflowUpdate.update(context.server)
    assert message =~ "Git fetch failed"
    git(context.checkout, ["remote", "set-url", "origin", context.remote])
    git(context.checkout, ["config", "user.email", "test@example.invalid"])
    git(context.checkout, ["config", "user.name", "Test"])
    git(context.checkout, ["commit", "--allow-empty", "-m", "Local commit"])
    local = git(context.checkout, ["rev-parse", "HEAD"])
    publish(context, prompt: "Remote change")
    assert {:error, message} = WorkflowUpdate.update(context.server)
    assert message =~ "fast-forward history"
    assert git(context.checkout, ["rev-parse", "HEAD"]) == local
  end

  test "stale preparation cannot overwrite a later update", context do
    revision = publish(context, prompt: "New prompt")
    candidate = %{root: context.checkout, before: context.before, revision: revision, workflow: %{}}
    assert {:ok, _} = WorkflowUpdate.update(context.server)
    assert {:error, message} = GenServer.call(context.server, {:apply_workflow_update, candidate})
    assert message =~ "changed during"
    assert git(context.checkout, ["rev-parse", "HEAD"]) == revision
  end

  test "failed activation restores previous revision and reloads it", context do
    revision = publish(context, prompt: "New prompt")
    git(context.checkout, ["fetch", "origin", "main"])
    candidate = %{root: context.checkout, before: context.before, revision: revision, workflow: %{}}
    assert {:error, message} = GenServer.call(context.server, {:apply_workflow_update, candidate})
    assert message =~ "previous revision was restored"
    assert git(context.checkout, ["rev-parse", "HEAD"]) == context.before
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()
  end

  test "standalone workflows and unavailable runtime report a readable error", context do
    Workflow.set_workflow_file_path(Path.join(context.root, "WORKFLOW.md"))
    assert {:error, message} = WorkflowUpdate.update(context.server)
    assert message =~ "repository-root"
    assert {:error, message} = WorkflowUpdate.update(__MODULE__.Missing)
    assert message =~ "Runtime unavailable"
  end

  test "edits made after preparation are preserved", context do
    revision = publish(context, prompt: "New prompt")
    candidate = %{root: context.checkout, before: context.before, revision: revision, workflow: %{}}
    path = Path.join(context.checkout, "WORKFLOW.md")
    File.write!(path, File.read!(path) <> "\nLocal edit")
    assert {:error, message} = GenServer.call(context.server, {:apply_workflow_update, candidate})
    assert message =~ "no local changes"
    assert File.read!(path) =~ "Local edit"
    assert git(context.checkout, ["rev-parse", "HEAD"]) == context.before
  end

  test "executable regular workflows can be updated", context do
    publish(context, prompt: "New prompt")
    File.chmod!(Path.join(context.seed, "WORKFLOW.md"), 0o755)
    commit_and_push(context.seed)
    assert {:ok, _} = WorkflowUpdate.update(context.server)
    assert {:ok, %{prompt: "New prompt"}} = Workflow.current()
  end

  test "malformed configuration keys cannot crash the updater", context do
    path = Path.join(context.seed, "WORKFLOW.md")
    content = File.read!(path)
    content = String.replace(content, "agent:\n", "agent:\n  max_concurrent_agents_by_state:\n    ? {bad: key}\n    : 2\n")
    File.write!(path, content)
    commit_and_push(context.seed)
    assert {:error, message} = WorkflowUpdate.update(context.server)
    assert message =~ "invalid"
    assert git(context.checkout, ["rev-parse", "HEAD"]) == context.before
  end

  test "missing host tools return an error without touching the checkout", context do
    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", context.root)
      assert {:error, _} = WorkflowUpdate.update(context.server)
    after
      System.put_env("PATH", original_path)
    end

    assert git(context.checkout, ["rev-parse", "HEAD"]) == context.before
  end

  test "failed merge cannot roll back a concurrently created local commit", context do
    publish(context, prompt: "New prompt")
    git(context.checkout, ["config", "user.email", "test@example.invalid"])
    git(context.checkout, ["config", "user.name", "Test"])
    bin = Path.join(context.root, "bin")
    File.mkdir_p!(bin)
    original_path = System.get_env("PATH")
    timeout = System.find_executable("timeout")

    File.write!(Path.join(bin, "timeout"), """
    #!/bin/sh
    if [ "${8}" = merge ]; then
      git -c core.hooksPath=/dev/null commit --allow-empty -m 'Concurrent local commit' >/dev/null
      exit 1
    fi
    exec #{timeout} "$@"
    """)

    File.chmod!(Path.join(bin, "timeout"), 0o755)

    try do
      System.put_env("PATH", bin <> ":" <> original_path)
      assert {:error, message} = WorkflowUpdate.update(context.server)
      assert message =~ "Operator intervention"
    after
      System.put_env("PATH", original_path)
    end

    assert git(context.checkout, ["log", "-1", "--format=%s"]) == "Concurrent local commit"
    refute git(context.checkout, ["rev-parse", "HEAD"]) == context.before
  end

  defp publish(context, options) do
    write_workflow_file!(Path.join(context.seed, "WORKFLOW.md"), Keyword.merge([tracker_kind: "memory", poll_interval_ms: 600_000], options))
    commit_and_push(context.seed)
  end

  defp commit_and_push(seed) do
    git(seed, ["add", "."])
    git(seed, ["commit", "-m", "Update workflow"])
    git(seed, ["push", "origin", "main"])
    git(seed, ["rev-parse", "HEAD"])
  end

  defp git(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(output)
  end
end
