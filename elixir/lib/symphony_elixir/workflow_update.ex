defmodule SymphonyElixir.WorkflowUpdate do
  @moduledoc """
  Fetches a repository workflow off the scheduler and applies it only while idle.
  """

  alias SymphonyElixir.{Config, Workflow, WorkflowStore}
  alias SymphonyElixir.Config.Schema

  @hot_sections %{"polling" => Schema.Polling, "agent" => Schema.Agent, "hooks" => Schema.Hooks, "codex" => Schema.Codex}

  @spec update(GenServer.server()) :: {:ok, String.t()} | {:error, String.t()}
  def update(orchestrator) do
    with :ok <- GenServer.call(orchestrator, :workflow_update_ready),
         {:ok, candidate} <- prepare() do
      GenServer.call(orchestrator, {:apply_workflow_update, candidate}, 60_000)
    end
  catch
    :exit, _ -> {:error, "Runtime unavailable. Check repository and workflow state before retrying."}
  end

  @doc false
  @spec apply(map()) :: {:ok, String.t()} | {:error, String.t()}
  def apply(%{root: root, before: before, revision: revision, workflow: workflow}) do
    with {:ok, ^root} <- repository(),
         :ok <- clean_main(root),
         {:ok, ^before} <- git(root, ["rev-parse", "HEAD"]) do
      if before == revision do
        {:ok, "Workflow is already up to date (#{short(revision)})."}
      else
        activate(root, before, revision, workflow)
      end
    else
      {:ok, _} -> {:error, "Repository changed during the update. Retry."}
      error -> error
    end
  end

  defp prepare do
    with {:ok, root} <- repository(),
         :ok <- clean_main(root),
         {:ok, before} <- git(root, ["rev-parse", "HEAD"]),
         {:ok, _} <- git(root, ["fetch", "--no-tags", "origin", "main"]),
         {:ok, revision} <- git(root, ["rev-parse", "FETCH_HEAD"]),
         {:ok, _} <- git(root, ["merge-base", "--is-ancestor", before, revision]),
         :ok <- regular_workflow(root, revision),
         {:ok, content} <- git(root, ["show", "#{revision}:WORKFLOW.md"]),
         {:ok, workflow} <- validate(content) do
      {:ok, %{root: root, before: before, revision: revision, workflow: workflow}}
    end
  end

  defp repository do
    path = Path.expand(Workflow.workflow_file_path())
    root = Path.dirname(path)

    with true <- Path.basename(path) == "WORKFLOW.md",
         {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, ^root} <- git(root, ["rev-parse", "--show-toplevel"]) do
      {:ok, root}
    else
      _ -> {:error, "Update requires a repository-root WORKFLOW.md."}
    end
  end

  defp clean_main(root) do
    with {:ok, "main"} <- git(root, ["symbolic-ref", "--short", "HEAD"]),
         {:ok, ""} <- git(root, ["status", "--porcelain", "--untracked-files=normal"]) do
      :ok
    else
      _ -> {:error, "Repository must be on main with no local changes. Nothing was updated."}
    end
  end

  defp regular_workflow(root, revision) do
    case git(root, ["ls-tree", revision, "--", "WORKFLOW.md"]) do
      {:ok, "100644 blob " <> _} -> :ok
      {:ok, "100755 blob " <> _} -> :ok
      _ -> {:error, "Candidate WORKFLOW.md must be a regular tracked file."}
    end
  end

  defp validate(content) do
    with {:ok, current} <- Workflow.current(),
         {:ok, workflow} <- Workflow.parse(content),
         :ok <- hot_change(current.config, workflow.config),
         {:ok, settings} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(settings),
         {:ok, _template} <- Solid.parse(workflow.prompt) do
      {:ok, workflow}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Candidate workflow is invalid. The current workflow was kept."}
    end
  rescue
    _ -> {:error, "Candidate workflow is invalid. The current workflow was kept."}
  end

  defp hot_change(before, candidate) do
    unchanged_resources? = Map.drop(before, Map.keys(@hot_sections)) == Map.drop(candidate, Map.keys(@hot_sections))

    known_changes? =
      Enum.all?(@hot_sections, fn {key, schema} ->
        fields = Enum.map(schema.__schema__(:fields), &Atom.to_string/1)
        old = Map.get(before, key, %{})
        new = Map.get(candidate, key, %{})
        old == new or (is_map(old) and is_map(new) and Map.drop(old, fields) == Map.drop(new, fields))
      end)

    if unchanged_resources? and known_changes? do
      :ok
    else
      {:error, "Configuration change requires a reviewed deployment; it cannot be applied by this button. The current workflow was kept."}
    end
  end

  defp activate(root, before, revision, workflow) do
    with {:ok, _} <- git(root, ["merge", "--ff-only", "--no-edit", revision]),
         :ok <- WorkflowStore.force_reload(),
         {:ok, ^workflow} <- WorkflowStore.current() do
      {:ok, "Updated workflow to #{short(revision)}. Existing issue workspaces were kept."}
    else
      _ -> rollback(root, before, revision)
    end
  end

  defp rollback(root, before, revision) do
    # --keep refuses to overwrite concurrent edits, unlike a hard reset.
    with {:ok, head} when head == before or head == revision <- git(root, ["rev-parse", "HEAD"]),
         {:ok, _} <- git(root, ["reset", "--keep", before]),
         :ok <- WorkflowStore.force_reload() do
      {:error, "Update failed; the previous revision was restored."}
    else
      _ -> {:error, "Update failed and rollback could not complete. Operator intervention is required."}
    end
  end

  defp git(root, args) do
    case System.cmd("timeout", ["--kill-after=2s", "20s", "git", "-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false" | args],
           cd: root,
           env: [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_SSH_COMMAND", "ssh -oBatchMode=yes -oConnectTimeout=10"}],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _} -> {:error, "Git #{hd(args)} failed or timed out. Check repository access and fast-forward history."}
    end
  rescue
    _ -> {:error, "Workflow update requires Git and GNU timeout on the service PATH."}
  end

  defp short(revision), do: String.slice(revision, 0, 8)
end
