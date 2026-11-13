defmodule Mix.Tasks.Instructions.Prepare do
  @moduledoc false
  use Mix.Task

  alias SymphonyElixir.{Instructions, Profile}

  @shortdoc "Stage a local instructions package from an immutable Git commit"

  @impl Mix.Task
  def run([id, revision, repo, workflow | required]) do
    with_profiles(fn -> Instructions.prepare(id, revision, repo, workflow, required) end)
  end

  def run(_args), do: Mix.raise("Usage: mix instructions.prepare PROFILE REVISION REPO WORKFLOW [REQUIRED_FILE ...]")

  @doc false
  @spec with_profiles((-> {:ok, Instructions.pin()} | {:error, atom()})) :: :ok
  def with_profiles(operation) do
    Mix.Task.run("app.config")
    manifest = System.get_env("SYMPHONY_PROFILES") || Mix.raise("Set SYMPHONY_PROFILES to the grouped manifest path.")
    {:ok, _apps} = Application.ensure_all_started(:crypto)

    with {:ok, profiles} <- Profile.load(manifest),
         {:ok, supervisor} <- Profile.start_link(profiles) do
      try do
        case operation.() do
          {:ok, pin} -> Mix.shell().info("Validated #{pin.profile_id} revision #{pin.revision} at #{pin.root}")
          {:error, reason} -> Mix.raise("Instructions check failed (#{reason}).")
        end
      after
        Supervisor.stop(supervisor)
      end
    else
      _ -> Mix.raise("Could not start profile configuration from the grouped manifest.")
    end
  end
end
