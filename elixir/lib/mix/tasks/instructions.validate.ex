defmodule Mix.Tasks.Instructions.Validate do
  @moduledoc false
  use Mix.Task

  alias Mix.Tasks.Instructions.Prepare
  alias SymphonyElixir.Instructions

  @shortdoc "Validate a staged instructions package for a grouped profile"

  @impl Mix.Task
  def run([id, path]) do
    Prepare.with_profiles(fn -> Instructions.validate(id, Path.expand(path)) end)
  end

  def run(_args), do: Mix.raise("Usage: mix instructions.validate PROFILE PACKAGE_DIR")
end
