defmodule SymphonyElixir.RuntimeControlConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema

  test "runtime controls are disabled unless explicitly configured" do
    assert {:ok, settings} = Schema.parse(%{})
    refute settings.runtime_control.enabled
    assert settings.runtime_control.members == []
  end

  test "enabled controls require a shared absolute path and registered service identity" do
    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{"runtime_control" => %{"enabled" => true}})

    for invalid <- [
          %{"path" => "relative.sqlite3"},
          %{"id" => "other"},
          %{"members" => ["be", "be"]},
          %{"members" => ["be", " "]},
          %{"members" => ["be", nil]},
          %{"members" => ["be", 123]},
          %{"heartbeat_timeout_ms" => 1_000},
          %{"quota_check_timeout_ms" => "invalid"},
          %{"heartbeat_interval_ms" => "invalid"},
          %{"heartbeat_timeout_ms" => "invalid"},
          %{"heartbeat_interval_ms" => 0},
          %{"heartbeat_timeout_ms" => -1}
        ] do
      assert {:error, {:invalid_workflow_config, _}} =
               Schema.parse(%{"runtime_control" => Map.merge(valid_config(), invalid)})
    end

    assert {:ok, settings} = Schema.parse(%{"runtime_control" => valid_config()})
    assert settings.runtime_control.id == "be"
    assert settings.runtime_control.quota_check_timeout_ms == 15_000
  end

  test "enabled timing fields cannot be cleared in a runtime-control changeset" do
    for field <- [:quota_check_timeout_ms, :heartbeat_interval_ms, :heartbeat_timeout_ms] do
      attrs = valid_config() |> Map.put(Atom.to_string(field), nil)
      changeset = Schema.RuntimeControl.changeset(%Schema.RuntimeControl{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, field)
    end
  end

  test "runtime path and identity resolve workflow environment references and reject missing ones" do
    path_env = "SYMPHONY_TEST_RUNTIME_PATH"
    id_env = "SYMPHONY_TEST_RUNTIME_ID"
    previous = %{path_env => System.get_env(path_env), id_env => System.get_env(id_env)}

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env(path_env, valid_config()["path"])
    System.put_env(id_env, "be")

    config = Map.merge(valid_config(), %{"path" => "$" <> path_env, "id" => "$" <> id_env})
    assert {:ok, settings} = Schema.parse(%{"runtime_control" => config})
    assert settings.runtime_control.path == valid_config()["path"]
    assert settings.runtime_control.id == "be"

    System.delete_env(path_env)
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"runtime_control" => config})
  end

  defp valid_config do
    %{
      "enabled" => true,
      "path" => Path.join(System.tmp_dir!(), "symphony-control.sqlite3"),
      "id" => "be",
      "members" => ["be", "fe", "landing"]
    }
  end
end
