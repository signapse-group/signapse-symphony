defmodule SymphonyElixir.Instructions do
  @moduledoc """
  Loads checkout instructions or pins operator-staged instructions for a grouped profile.
  """

  import Bitwise, only: [band: 2]

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{InstructionReferences, PathSafety, Profile, PromptBuilder, Workflow, WorkflowStore}
  alias SymphonyElixir.Jira.Client
  alias SymphonyElixir.Tracker.Issue

  @manifest "instructions.json"
  @revision_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
  @qa_operations ~w(qa-generate qa-execute qa-retest)
  @checkout_runbook_prefix "docs/runbooks/"

  @type pin :: %{
          profile_id: String.t(),
          revision: String.t(),
          fingerprint: binary(),
          root: Path.t(),
          workflow_path: Path.t(),
          workflow: Workflow.loaded_workflow()
        }

  @type prompt_pin :: %{
          required(:profile_id) => String.t(),
          required(:revision) => String.t(),
          required(:root) => Path.t(),
          required(:workflow_path) => Path.t(),
          required(:workflow) => Workflow.loaded_workflow(),
          optional(:fingerprint) => binary()
        }

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
         :ok <- clone_upstream(root, upstream, path, snapshot),
         {:ok, revision} <- checkout_head(root),
         {:ok, branch} <- git(root, ["symbolic-ref", "--short", "HEAD"]),
         true <- String.trim(branch) == upstream.branch,
         {:ok, source_root} <- checkout_source_root(snapshot, root, revision) do
      run.(%{root: source_root, revision: revision})
    else
      _ -> checkout_failure(:checkout_upstream_unavailable, path)
    end
  end

  defp checkout_source_root(
         %{profile_id: "qa", instructions_root: instructions_root, env: %{"SYMPHONY_QA_SEALED_UPSTREAM" => "1"}},
         _checkout,
         revision
       ) do
    sealed = Path.join([instructions_root, "revisions", revision])

    with {:ok, ^sealed} <- PathSafety.canonicalize(sealed),
         {:ok, %File.Stat{type: :directory, uid: 0}} <- File.lstat(sealed),
         {options, 0} <- System.cmd("/usr/bin/findmnt", ["-rn", "-o", "OPTIONS", "--target", sealed]),
         true <- "ro" in String.split(String.trim(options), ",") do
      {:ok, sealed}
    else
      _ -> {:error, :checkout_upstream_unavailable}
    end
  end

  defp checkout_source_root(_snapshot, checkout, _revision), do: {:ok, checkout}

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

    with :ok <- run_git_upstream(args ++ clone, env),
         :ok <- run_git_upstream(args ++ sparse, env) do
      run_git_upstream(args ++ ["-C", root, "checkout", "--force"], env)
    end
  end

  defp run_git_upstream(args, env) do
    case System.cmd("timeout", args, env: env, stderr_to_stdout: true) do
      {_output, 0} -> :ok
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

  @spec status(String.t()) :: {:ok, %{revision: String.t()}} | {:error, atom()}
  def status(id) do
    with {:ok, root} <- instructions_root(id),
         {:ok, revision} <- active_revision(root) do
      {:ok, %{revision: revision}}
    end
  end

  @spec pin(String.t()) :: {:ok, pin()} | {:error, atom()}
  def pin(id) do
    with {:ok, root} <- instructions_root(id),
         {:ok, revision} <- active_revision(root) do
      validate_revision(id, root, revision)
    end
  end

  @spec activate(String.t(), String.t()) :: {:ok, pin()} | {:error, atom()}
  def activate(id, revision) do
    with {:ok, root} <- instructions_root(id),
         {:ok, pin} <- validate_revision(id, root, revision),
         :ok <- replace_active(root, revision) do
      {:ok, pin}
    end
  end

  @spec validate(String.t(), Path.t()) :: {:ok, pin()} | {:error, atom()}
  def validate(id, package) do
    with {:ok, settings} <- tracker_settings(id),
         {:ok, ^package} <- PathSafety.canonicalize(package),
         read = fn path -> read_sealed_file(package, path) end,
         {:ok, manifest} <- read_manifest(read),
         :ok <- match_profile(manifest, id, Path.basename(package)),
         {:ok, pin, _files} <- preflight(manifest, package, settings, read) do
      {:ok, pin}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :unsafe_instructions_package}
    end
  end

  @spec prepare(String.t(), String.t(), Path.t(), Path.t(), [Path.t()]) :: {:ok, pin()} | {:error, atom()}
  def prepare(id, revision, repo, workflow, required) do
    with {:ok, root} <- instructions_root(id),
         {:ok, settings} <- tracker_settings(id),
         {:ok, commit} <- git_commit(repo, revision),
         {:ok, destination} <- destination(root, commit),
         manifest = %{"profile_id" => id, "revision" => commit, "workflow" => workflow, "required_files" => required},
         read = fn path -> read_git_file(repo, commit, path) end,
         {:ok, pin, files} <- preflight(manifest, destination, settings, read),
         :ok <- publish(destination, manifest, files) do
      {:ok, pin}
    end
  end

  defp instructions_root(id) do
    case Profile.lookup(id) do
      {:ok, %{checkout_workflow: path}} when is_binary(path) -> {:error, :checkout_instructions_enabled}
      {:ok, %{instructions_root: root}} when is_binary(root) -> canonical_root(root)
      {:ok, _profile} -> {:error, :missing_instructions_root}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_root(root) do
    case PathSafety.canonicalize(root) do
      {:ok, ^root} -> {:ok, root}
      _ -> {:error, :unsafe_instructions_package}
    end
  end

  defp tracker_settings(id) do
    case WorkflowStore.snapshot(id) do
      {:ok, snapshot} -> {:ok, snapshot.settings.tracker}
      {:error, _reason} -> {:error, :profile_workflow_unavailable}
    end
  end

  defp active_revision(root) do
    with {:ok, text} <- InstructionReferences.read_regular(root, "active"),
         true <- String.valid?(text),
         revision = String.trim(text),
         true <- valid_revision?(revision) do
      {:ok, revision}
    else
      _ -> {:error, :missing_active_instructions}
    end
  end

  defp validate_revision(id, root, revision) do
    with {:ok, package} <- package_path(root, revision) do
      validate(id, package)
    end
  end

  defp package_path(root, revision) do
    if valid_revision?(revision) do
      {:ok, Path.join([root, "revisions", revision])}
    else
      {:error, :invalid_instructions_revision}
    end
  end

  defp valid_revision?(revision) when is_binary(revision), do: Regex.match?(@revision_pattern, revision)
  defp valid_revision?(_revision), do: false

  defp read_manifest(read) do
    with {:ok, content} <- read.(@manifest),
         {:ok, manifest} <- Jason.decode(content) do
      {:ok, manifest}
    else
      _ -> {:error, :invalid_instructions_manifest}
    end
  end

  defp match_profile(%{"profile_id" => id, "revision" => revision}, id, revision), do: :ok
  defp match_profile(_manifest, _id, _revision), do: {:error, :instructions_identity_mismatch}

  defp preflight(manifest, root, settings, read) do
    with {:ok, relative_workflow, required} <- package_paths(manifest),
         {:ok, workflow} <- load_workflow(relative_workflow, read),
         pin = pin_info(manifest, root, relative_workflow, workflow),
         {:ok, prompts} <- render_phases(pin, settings),
         {:ok, files} <- InstructionReferences.collect(root, relative_workflow, required, prompts, read) do
      fingerprint = package_fingerprint(manifest, files)
      {:ok, Map.put(pin, :fingerprint, fingerprint), files}
    end
  end

  defp package_fingerprint(manifest, files) do
    :crypto.hash(:sha256, :erlang.term_to_binary({manifest, files}, [:deterministic]))
  end

  defp package_paths(%{"workflow" => path, "required_files" => required}) when is_list(required) do
    if Enum.all?([path | required], &valid_relative_path?/1) do
      {:ok, path, Enum.uniq(["AGENTS.md" | required])}
    else
      {:error, :invalid_instructions_manifest}
    end
  end

  defp package_paths(_manifest), do: {:error, :invalid_instructions_manifest}

  defp valid_relative_path?(path) when is_binary(path) and byte_size(path) > 0 do
    Path.type(path) == :relative and not String.contains?(path, [<<0>>, "\r", "\n", "\\"]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", "..", @manifest]))
  end

  defp valid_relative_path?(_path), do: false

  defp load_workflow(path, read) do
    with {:ok, content} <- read.(path),
         true <- String.valid?(content),
         {:ok, %{prompt_template: prompt} = workflow} when prompt != "" <- Workflow.parse(content) do
      {:ok, workflow}
    else
      _ -> {:error, :invalid_instructions_workflow}
    end
  end

  defp pin_info(manifest, root, path, workflow) do
    %{profile_id: manifest["profile_id"], revision: manifest["revision"], root: root, workflow_path: Path.join(root, path), workflow: workflow}
  end

  defp render_phases(pin, settings) do
    states = Enum.uniq(settings.dispatch_states ++ settings.active_states)
    operations = if pin.profile_id == "qa", do: @qa_operations, else: [nil]

    prompts =
      for state <- states, operation <- operations, attempt <- [nil, 1] do
        issue = phase_fixture(pin.profile_id, state, settings.required_labels, operation)
        PromptBuilder.render_instructions(issue, attempt, pin)
      end

    {:ok, prompts}
  rescue
    _error -> {:error, :instructions_render_failed}
  end

  defp phase_fixture(profile_id, state, labels, operation) do
    native_ref =
      if profile_id == "planning" do
        %{issue_type: %{name: "Story", subtask: false}, parent: nil}
      else
        %{issue_type: %{name: "Subtask", subtask: true}, parent: %{key: "SIGN-0", id: "0"}}
      end

    %Issue{
      id: "1",
      identifier: "SIGN-1",
      title: "Instructions validation",
      description: "Synthetic work item",
      url: "https://jira.example.invalid/browse/SIGN-1",
      native_ref: native_ref,
      state: state,
      labels: if(operation, do: labels ++ [operation], else: labels)
    }
  end

  defp read_sealed_file(root, path) do
    with {:ok, content} <- InstructionReferences.read_regular(root, path),
         {:ok, stat} <- File.stat(Path.join(root, path)),
         true <- band(stat.mode, 0o444) != 0 and band(stat.mode, 0o222) == 0 do
      {:ok, content}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :writable_instruction_file}
    end
  end

  defp replace_active(root, revision) do
    temporary = Path.join(root, ".active-#{unique_suffix()}")

    try do
      with :ok <- File.write(temporary, revision <> "\n", [:exclusive]),
           :ok <- File.rename(temporary, Path.join(root, "active")) do
        :ok
      else
        _ -> {:error, :instructions_activation_failed}
      end
    after
      File.rm(temporary)
    end
  end

  defp git_commit(repo, revision) do
    with true <- valid_revision?(revision),
         {:ok, commit} <- git(repo, ["rev-parse", "--verify", "--end-of-options", revision <> "^{commit}"]),
         commit = String.trim(commit),
         true <- Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, commit) do
      {:ok, commit}
    else
      _ -> {:error, :invalid_instructions_git_revision}
    end
  end

  defp read_git_file(repo, commit, path) do
    with {:ok, entry} <- git(repo, ["--literal-pathspecs", "ls-tree", commit, "--", path]),
         true <- String.starts_with?(entry, ["100644 blob ", "100755 blob "]),
         {:ok, content} <- git(repo, ["show", commit <> ":" <> path]) do
      {:ok, content}
    else
      _ -> {:error, :missing_or_unsafe_instruction_file}
    end
  end

  defp git(repo, args) do
    case System.cmd("git", args, cd: repo, env: [{"GIT_NO_LAZY_FETCH", "1"}, {"GIT_TERMINAL_PROMPT", "0"}], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> {:error, :instructions_git_error}
    end
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :instructions_git_error}
  end

  defp destination(root, commit) do
    with {:ok, path} <- package_path(root, commit),
         {:ok, ^path} <- PathSafety.canonicalize(path),
         {:error, :enoent} <- File.lstat(path) do
      {:ok, path}
    else
      {:ok, %File.Stat{}} -> {:error, :instructions_revision_exists}
      _ -> {:error, :unsafe_instructions_package}
    end
  end

  defp publish(destination, manifest, files) do
    directory = Path.dirname(destination)
    temporary = Path.join(directory, ".stage-#{unique_suffix()}")

    try do
      with :ok <- File.mkdir_p(directory),
           :ok <- File.mkdir(temporary),
           :ok <- write_files(temporary, Map.put(files, @manifest, Jason.encode!(manifest))),
           :ok <- File.rename(temporary, destination) do
        :ok
      else
        _ -> {:error, :instructions_staging_failed}
      end
    after
      File.rm_rf(temporary)
    end
  end

  defp write_files(root, files) do
    Enum.reduce_while(files, :ok, fn {relative, content}, :ok ->
      path = Path.join(root, relative)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, content, [:exclusive]),
           :ok <- File.chmod(path, 0o444) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp unique_suffix, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
