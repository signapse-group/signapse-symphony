defmodule SymphonyElixir.PathSafetyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PathSafety

  @tag :tmp_dir
  @tag timeout: 2_000
  test "rejects a symlink cycle when validating a workspace or profile root", %{tmp_dir: root} do
    first = Path.join(root, "first")
    second = Path.join(root, "second")
    File.ln_s!(second, first)
    File.ln_s!(first, second)

    assert {:error, {:path_canonicalize_failed, ^first, :eloop}} = PathSafety.canonicalize(first)
  end
end
