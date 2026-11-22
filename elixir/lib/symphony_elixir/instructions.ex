defmodule SymphonyElixir.Instructions do
  @moduledoc """
  Loads published checkout instructions for a grouped worker attempt.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{InstructionReferences, PathSafety, Profile, PromptBuilder}
  alias SymphonyElixir.Jira.Client
  alias SymphonyElixir.Tracker.Issue

  @checkout_runbook_prefix "docs/runbooks/"

  @type checkout_template :: %{template: String.t(), workflow_path: Path.t(), workflow_digest: String.t()}
  @type checkout_prompt :: %{
          required(:prompt) => String.t(),
          required(:workflow_path) => Path.t(),
          required(:workflow_digest) => String.t(),
          optional(:source) => upstream()
        }
  @type checkout_failure :: {:checkout_instructions, atom(), Path.t()}
  @type upstream :: %{root: Path.t(), revision: String.t()}

  @doc false
  @spec with_checkout_upstream(map() | nil, String.t() | nil, (upstream() | nil -> term())) :: term()
  def with_checkout_upstream(%{checkout_upstream: upstream, checkout_workflow: path} = snapshot, worker_host, run) when is_map(upstream) do
    parent = Path.join(System.tmp_dir!(), "symphony-checkout-#{unique_suffix()}")

    with true <- is_nil(worker_host),
         :ok <- File.mkdir(parent) do
      try do
        result = start_upstream(parent, upstream, path, snapshot, run)
        File.rm_rf(parent)
        result
      catch
        :exit, {:session_stop_unconfirmed, _reason} = error ->
          exit(error)

        kind, reason ->
          File.rm_rf(parent)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      _ -> checkout_failure(:checkout_upstream_unavailable, path)
    end
  end

  def with_checkout_upstream(_snapshot, _worker_host, run), do: run.(nil)

  defp start_upstream(parent, upstream, path, snapshot, run) do
    root = Path.join(parent, "source")

    with :ok <- File.chmod(parent, 0o700),
         {:ok, _} <- clone_upstream(root, upstream, path, snapshot),
         {:ok, revision} <- checkout_head(root),
         {:ok, branch} <- git(root, ["symbolic-ref", "--short", "HEAD"]),
         true <- String.trim(branch) == upstream.branch do
      run.(%{root: root, revision: revision})
    else
      _ -> checkout_failure(:checkout_upstream_unavailable, path)
    end
  end

  defp clone_upstream(root, %{repository: repository, branch: branch}, path, snapshot) do
    auth = credential_args(snapshot.env)
    env = Profile.subprocess_env(snapshot, Client.secret_environment_names(snapshot.settings.tracker))
    env = Enum.into([{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}], Map.new(env)) |> Map.to_list()
    args = ["--kill-after=5s", "90s", "git", "-c", "core.hooksPath=/dev/null", "-c", "http.followRedirects=false"] ++ auth
    clone = ["clone", "--quiet", "--depth=1", "--filter=blob:none", "--no-checkout", "--no-tags", "--branch", branch, "--", repository, root]

    sparse = [
      "-C",
      root,
      "sparse-checkout",
      "set",
      "--no-cone",
      "*.md",
      "*.mjs",
      "*.exs",
      "/.agents/skills/",
      "/scripts/",
      "/docs/examples/",
      "/.env.example",
      "/" <> path
    ]

    with {:ok, _} <- run_upstream_command(args ++ clone, env),
         {:ok, _} <- run_upstream_command(args ++ sparse, env) do
      run_upstream_command(args ++ ["-C", root, "checkout", "--force"], env)
    end
  end

  defp run_upstream_command(args, env) do
    case System.cmd("timeout", args, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> {:error, :checkout_upstream_unavailable}
    end
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :checkout_upstream_unavailable}
  end

  defp credential_args(%{"SYMPHONY_GIT_CREDENTIAL_HELPER" => helper}) when byte_size(helper) > 0, do: ["-c", "credential.helper=#{helper}"]
  defp credential_args(%{"GITHUB_TOKEN" => token}) when byte_size(token) > 0, do: ["-c", "credential.helper=!gh auth git-credential"]
  defp credential_args(_env), do: []

  @spec checkout_template(Path.t(), Path.t()) :: {:ok, checkout_template()} | {:error, atom()}
  def checkout_template(workspace, workflow_path) do
    with true <- PathSafety.repository_relative?(workflow_path),
         {:ok, template} <- checkout_workflow_file(workspace, workflow_path),
         false <- Regex.match?(~r/\A(?:\x{FEFF})?---[\t ]*(?:\R|\z)/u, template) do
      normalized = template |> String.replace("\r\n", "\n") |> String.trim()
      {:ok, %{template: normalized, workflow_path: workflow_path, workflow_digest: digest(template)}}
    else
      {:error, {:checkout_instructions, code, _path}} -> {:error, code}
      _ -> {:error, :checkout_workflow_invalid}
    end
  end

  defp checkout_workflow_file(workspace, workflow_path),
    do: checkout_file(workspace, workflow_path, :checkout_workflow_missing, :checkout_workflow_invalid)

  @spec checkout_prompt(Path.t(), Path.t(), Issue.t(), Schema.t(), non_neg_integer() | nil) ::
          {:ok, checkout_prompt()} | {:error, atom()}
  def checkout_prompt(workspace, workflow_path, issue, settings, attempt \\ nil) do
    case prepare_checkout(workspace, workflow_path, issue, settings, attempt) do
      {:error, {:checkout_instructions, code, _path}} -> {:error, code}
      {:ok, _prompt} = result -> result
    end
  end

  @doc false
  @spec prepare_checkout(Path.t(), Path.t(), Issue.t(), Schema.t(), non_neg_integer() | nil, upstream() | nil) ::
          {:ok, checkout_prompt()} | {:error, checkout_failure()}
  def prepare_checkout(workspace, workflow_path, issue, settings, attempt, source \\ nil) do
    profile_id = settings.runtime_control.id

    with {:ok, %{template: template, workflow_digest: digest}} <- checkout_template(workspace, workflow_path),
         {:ok, prompt} <- PromptBuilder.render_checkout(issue, attempt, template, profile_id),
         {:ok, _agents} <- checkout_file(workspace, "AGENTS.md", :checkout_agents_missing, :checkout_agents_invalid),
         :ok <- checkout_skills(workspace),
         :ok <- checkout_phase_requirements(workspace, workflow_path, template, prompt, issue, settings) do
      checkout = %{prompt: prompt, workflow_path: workflow_path, workflow_digest: digest}
      {:ok, checkout_guidance(checkout, source)}
    else
      {:error, {:checkout_instructions, _code, _path}} = error -> error
      {:error, code} -> checkout_failure(code, workflow_path)
    end
  end

  defp checkout_guidance(checkout, nil) do
    opening = "Read AGENTS.md in the working directory. Resolve links in the workflow below relative to #{checkout.workflow_path} in this checkout.\n\n"
    %{checkout | prompt: opening <> checkout.prompt}
  end

  defp checkout_guidance(checkout, %{root: root, revision: revision} = source) do
    opening = "Use instructions revision #{revision}. Read #{Path.join(root, "AGENTS.md")} before working. Resolve instruction links from #{Path.join(root, checkout.workflow_path)}.\n\n"
    checkout |> Map.put(:prompt, opening <> checkout.prompt) |> Map.put(:source, source)
  end

  @doc false
  @spec checkout_head(Path.t()) :: {:ok, String.t()} | {:error, :checkout_head_unavailable}
  def checkout_head(workspace) do
    with {:ok, root} <- git(workspace, ["rev-parse", "--show-toplevel"]),
         true <- Path.expand(String.trim(root)) == Path.expand(workspace),
         {:ok, revision} <- git(workspace, ["rev-parse", "--verify", "HEAD^{commit}"]),
         revision = String.trim(revision),
         true <- Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, revision) do
      {:ok, revision}
    else
      _ -> {:error, :checkout_head_unavailable}
    end
  end

  defp checkout_skills(workspace) do
    relative = ".agents/skills"
    path = Path.join(workspace, relative)

    case File.lstat(path) do
      {:error, :enoent} -> checkout_failure(:checkout_skills_missing, relative)
      {:ok, %{type: :directory}} -> validate_skills_directory(workspace, path, relative)
      _ -> checkout_failure(:checkout_skills_invalid, relative)
    end
  end

  defp validate_skills_directory(workspace, path, relative) do
    with {:ok, ^path} <- PathSafety.canonicalize(path),
         {:ok, entries} <- File.ls(path),
         true <- Enum.any?(entries, &valid_skill?(workspace, relative, &1)) do
      :ok
    else
      _ -> checkout_failure(:checkout_skills_invalid, relative)
    end
  end

  defp valid_skill?(workspace, relative, entry) do
    match?({:ok, _}, checkout_file(workspace, Path.join([relative, entry, "SKILL.md"]), :checkout_skills_missing, :checkout_skills_invalid))
  end

  defp checkout_phase_requirements(workspace, workflow, template, prompt, issue, settings) do
    profile_id = settings.runtime_control.id

    case InstructionReferences.checkout_requirements(workspace, workflow, template, prompt, profile_id) do
      {:ok, requirements} ->
        verify_checkout_requirements(workspace, Enum.uniq(required_review_skill(issue, settings) ++ requirements), true)

      {:error, _reason} ->
        checkout_failure(:checkout_required_file_invalid, workflow)
    end
  end

  defp verify_checkout_requirements(workspace, requirements, check_runbooks?) do
    Enum.reduce_while(requirements, :ok, fn {path, anchor}, :ok ->
      with {:ok, content} <- checkout_required_file(workspace, path),
           :ok <- InstructionReferences.checkout_anchor(content, anchor),
           :ok <- checkout_runbook_requirements(workspace, path, content, check_runbooks?) do
        {:cont, :ok}
      else
        {:error, {:checkout_instructions, _code, _path}} = error -> {:halt, error}
        {:error, _reason} -> {:halt, checkout_failure(:checkout_required_file_invalid, path)}
      end
    end)
  end

  defp checkout_required_file(workspace, path),
    do: checkout_file(workspace, path, :checkout_required_file_missing, :checkout_required_file_invalid)

  defp checkout_runbook_requirements(workspace, @checkout_runbook_prefix <> _ = path, content, true) do
    with {:ok, requirements} <- InstructionReferences.checkout_requirements(workspace, path, content, content, nil) do
      verify_checkout_requirements(workspace, Enum.uniq(requirements), false)
    end
  end

  defp checkout_runbook_requirements(_workspace, _path, _content, _check_runbooks?), do: :ok

  defp required_review_skill(%Issue{state: state}, %{runtime_control: %{id: "fe"}, tracker: %{review_state: review}})
       when is_binary(state) and is_binary(review) do
    if Schema.normalize_issue_state(state) == Schema.normalize_issue_state(review),
      do: [{".agents/skills/code-review/SKILL.md", nil}],
      else: []
  end

  defp required_review_skill(_issue, _settings), do: []

  defp checkout_file(workspace, path, missing, invalid) do
    absolute = Path.join(workspace, path)

    with true <- PathSafety.repository_relative?(path),
         {:ok, ^absolute} <- PathSafety.canonicalize(absolute),
         {:ok, %{type: :regular}} <- File.lstat(absolute),
         {:ok, content} <- File.read(absolute),
         true <- String.valid?(content) and not String.contains?(content, <<0>>) and String.trim(content) != "" do
      {:ok, content}
    else
      {:error, :enoent} -> checkout_failure(missing, path)
      _ -> checkout_failure(invalid, path)
    end
  end

  defp checkout_failure(code, path), do: {:error, {:checkout_instructions, code, path}}

  defp digest(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp git(repo, args) do
    case System.cmd("git", args, cd: repo, env: [{"GIT_NO_LAZY_FETCH", "1"}, {"GIT_TERMINAL_PROMPT", "0"}], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> {:error, :instructions_git_error}
    end
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :instructions_git_error}
  end

  defp unique_suffix, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
