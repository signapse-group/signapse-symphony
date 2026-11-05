defmodule SymphonyElixir.SessionProcessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.SessionProcess

  @tag timeout: 25_000
  test "the stop budget retains late bounded diagnostics instead of killing the helper" do
    root = Path.join(System.tmp_dir!(), "symphony-stop-budget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_path = System.get_env("PATH")
    System.put_env("PATH", root <> ":" <> previous_path)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf!(root)
    end)

    unit = "symphony-session-" <> String.duplicate("a", 32) <> ".service"
    diagnostic = Jason.encode!(%{unit: unit, reason: "cgroup_populated_timeout", snapshot: "sampled", cgroup_events: %{populated: 1}})

    File.write!(Path.join(root, "python3"), """
    #!/bin/sh
    sleep 15.1
    printf '%s\\n' 'private unrelated stderr' >&2
    printf '%s\\n' 'SYMPHONY_SESSION_STOP #{diagnostic}' >&2
    exit 3
    """)

    File.chmod!(Path.join(root, "python3"), 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: 100)
    session = %{containment: %{unit: unit, invocation: String.duplicate("b", 32)}, worker_host: nil}

    log =
      capture_log(fn ->
        assert {:error, {:session_stop_unconfirmed, {:ok, {:ok, {output, 3}}}}} = SessionProcess.stop(session)
        assert output =~ diagnostic
      end)

    assert log =~ "cgroup_populated_timeout"
    assert log =~ "populated"
    refute log =~ "private unrelated stderr"
  end
end
