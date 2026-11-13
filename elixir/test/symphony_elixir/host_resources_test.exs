defmodule SymphonyElixir.HostResourcesTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.HostResources

  @tag :tmp_dir
  test "samples the limiting ancestor and shared lock without taking the lock", %{tmp_dir: root} do
    proc = Path.join(root, "proc")
    groups = Path.join(root, "cgroup")
    slice = Path.join(groups, "user.slice")
    unit = Path.join(slice, "symphony.service")
    lock = Path.join(root, "browser.lock")

    File.mkdir_p!(Path.join(proc, "self"))
    File.mkdir_p!(unit)
    File.write!(lock, "")
    File.write!(Path.join(proc, "self/cgroup"), "0::/user.slice/symphony.service\n")
    File.write!(Path.join(proc, "meminfo"), "MemAvailable: 1234 kB\nSwapTotal: 4096 kB\nSwapFree: 1024 kB\n")

    %{major_device: device, inode: inode} = File.stat!(lock)
    major = Bitwise.band(Bitwise.bsr(device, 8), 0xFFF)
    minor = Bitwise.bor(Bitwise.band(device, 0xFF), Bitwise.band(Bitwise.bsr(device, 12), 0xFFFFFF00))
    identity = "#{Integer.to_string(major, 16)}:#{Integer.to_string(minor, 16)}:#{inode}"
    File.write!(Path.join(proc, "locks"), "12: POSIX ADVISORY WRITE 12 #{identity} 0 EOF\n13: FLOCK ADVISORY WRITE 12 #{identity} 0 EOF\n")

    for {name, contents} <- [
          {"memory.high", "8053063680\n"},
          {"memory.max", "8589934592\n"},
          {"memory.current", "7300000000\n"},
          {"memory.swap.current", "1024\n"},
          {"memory.events", "high 100\noom_kill 0\n"},
          {"memory.pressure", "some avg10=10.00 avg60=1.00 avg300=1.00 total=314\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"},
          {"io.pressure", "some avg10=11.00 avg60=1.00 avg300=1.00 total=317\nfull avg10=1.00 avg60=0.00 avg300=0.00 total=24\n"}
        ] do
      File.write!(Path.join(slice, name), contents)
    end

    File.write!(Path.join(unit, "memory.high"), "max\n")
    File.write!(Path.join(unit, "memory.max"), "max\n")

    pid = start_supervised!({HostResources, proc_root: proc, cgroup_root: groups, browser_lock: lock})
    :sys.get_state(pid)

    assert {:ok,
            %{
              source: :local,
              runtime_cgroup: "/user.slice/symphony.service",
              cgroup: "/user.slice",
              memory_current_bytes: 7_300_000_000,
              memory_high_bytes: 8_053_063_680,
              memory_max_bytes: 8_589_934_592,
              cgroup_swap_bytes: 1_024,
              host_memory_available_bytes: 1_263_616,
              host_swap_total_bytes: 4_194_304,
              host_swap_used_bytes: 3_145_728,
              memory_events_high: 100,
              memory_some_us: 314,
              io_full_us: 24,
              browser_lock: :locked,
              delta: nil
            }} = HostResources.snapshot(nil)

    File.write!(Path.join(proc, "locks"), "13: FLOCK ADVISORY WRITE 12 00:00:#{inode} 0 EOF\n")
    send(pid, :sample)
    :sys.get_state(pid)
    assert {:ok, %{browser_lock: :unlocked}} = HostResources.snapshot(nil)

    File.write!(Path.join(proc, "locks"), String.duplicate("0", 65_537))
    send(pid, :sample)
    :sys.get_state(pid)
    assert {:ok, %{browser_lock: :unknown}} = HostResources.snapshot(nil)

    File.write!(Path.join(proc, "locks"), "")
    send(pid, :sample)
    :sys.get_state(pid)
    assert {:ok, %{browser_lock: :unlocked}} = HostResources.snapshot(nil)

    File.write!(Path.join(slice, "memory.events"), "high invalid\noom_kill 0\n")
    send(pid, :sample)
    :sys.get_state(pid)
    assert :unavailable = HostResources.snapshot(nil)

    File.rm!(Path.join(slice, "memory.events"))
    send(pid, :sample)
    :sys.get_state(pid)
    assert :unavailable = HostResources.snapshot(nil)
  end

  test "classifies pressure only from fresh, contiguous local intervals" do
    assert :unavailable = HostResources.snapshot(nil)
    assert :unavailable = HostResources.snapshot("qa-remote")
    assert :unknown = HostResources.pressure("qa-remote", 17_000)
    assert :unknown = HostResources.pressure(nil, 0)

    :ets.new(HostResources, [:named_table, :protected])
    assert :unavailable = HostResources.snapshot(nil)
    now = System.monotonic_time(:millisecond)

    high = timeline(now, 3, 500_000, 0)
    :ets.insert(HostResources, {:samples, high})
    assert :pressured = HostResources.pressure(nil, 17_000)
    assert {:ok, %{delta: %{interval_ms: 5_000, memory_events_high: 3, memory_some_us: 500_000}}} = HostResources.snapshot(nil)

    :ets.insert(HostResources, {:samples, timeline(now, 0, 500_000, 999_999)})
    assert :clear = HostResources.pressure(nil, 17_000)

    :ets.insert(HostResources, {:samples, timeline(now, 0, 0, 1_000_000)})
    assert :pressured = HostResources.pressure(nil, 17_000)

    [latest | previous] = timeline(now, 0, 0, 0)
    :ets.insert(HostResources, {:samples, [%{latest | io_full_us: 1_000_000} | previous]})
    assert :clear = HostResources.pressure(nil, 17_000)

    :ets.insert(HostResources, {:samples, [%{latest | oom_kill: 1} | previous]})
    assert :pressured = HostResources.pressure(nil, 17_000)

    :ets.insert(HostResources, {:samples, [%{latest | sampled_at_ms: now - 11_000} | previous]})
    assert :unknown = HostResources.pressure(nil, 17_000)
    assert :unavailable = HostResources.snapshot(nil)

    :ets.insert(HostResources, {:samples, high |> List.delete_at(1) |> List.delete_at(1)})
    assert :unknown = HostResources.pressure(nil, 17_000)

    :ets.insert(HostResources, {:samples, Enum.drop(high, -1)})
    assert :unknown = HostResources.pressure(nil, 17_000)

    :ets.insert(HostResources, {:samples, high})
    assert :unknown = HostResources.pressure(nil, 3_000)

    [latest | previous] = high
    :ets.insert(HostResources, {:samples, [%{latest | memory_events_high: 0} | previous]})
    assert :unknown = HostResources.pressure(nil, 17_000)
    assert {:ok, %{delta: nil}} = HostResources.snapshot(nil)

    :ets.insert(HostResources, {:samples, [%{latest | cgroup_inode: 2} | previous]})
    assert :unknown = HostResources.pressure(nil, 17_000)
  end

  defp timeline(now, high, memory_some_us, io_full_us) do
    for n <- 4..0//-1 do
      %{
        sampled_at_ms: now - 1_000 - (4 - n) * 5_000,
        cgroup: "/user.slice",
        runtime_cgroup: "/user.slice/symphony.service",
        cgroup_inode: 1,
        memory_events_high: high * n,
        oom_kill: 0,
        memory_some_us: memory_some_us * n,
        io_full_us: io_full_us * n
      }
    end
  end
end
