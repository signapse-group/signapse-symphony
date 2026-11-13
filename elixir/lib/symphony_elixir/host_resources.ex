defmodule SymphonyElixir.HostResources do
  @moduledoc """
  Samples local cgroup pressure for worker diagnostics and infrastructure retries.

  Samples every five seconds and retains ten minutes of history. Classifies
  local inactivity only when the sample sequence covers the window without
  counter resets or gaps longer than ten seconds. Fully observed intervals
  count toward a pressure finding when memory PSI some with high-limit reclaim
  covers 10% of measured time, I/O PSI full covers 20%, or an OOM kill occurs.
  """

  use GenServer
  import Bitwise

  @interval_ms 5_000
  @max_gap_ms 2 * @interval_ms
  @history_size div(10 * 60 * 1_000, @interval_ms) + 2
  @memory_stall_percent 10
  @io_stall_percent 20
  @counters [:memory_events_high, :oom_kill, :memory_some_us, :io_full_us]
  @browser_lock "/opt/apps/symphony/runtime/locks/signapse-ui-integration.lock"
  @max_locks_bytes 64 * 1_024

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the latest local sample and its deltas, if fresh."
  @spec snapshot(String.t() | nil) :: {:ok, map()} | :unavailable
  def snapshot(nil) do
    history = samples()
    now = System.monotonic_time(:millisecond)

    with [latest | previous] <- history,
         age when age in 0..@max_gap_ms <- now - latest.sampled_at_ms do
      {:ok, Map.merge(latest, %{age_ms: age, delta: interval(latest, List.first(previous))})}
    else
      _ -> :unavailable
    end
  end

  def snapshot(_remote), do: :unavailable

  @doc "Classifies pressure from measured intervals within a local worker's inactivity window."
  @spec pressure(String.t() | nil, non_neg_integer()) :: :pressured | :clear | :unknown
  def pressure(nil, elapsed_ms) when is_integer(elapsed_ms) and elapsed_ms > 0 do
    history = samples()
    now = System.monotonic_time(:millisecond)
    since = now - elapsed_ms

    with {[latest | _] = recent, [baseline | _]} <- Enum.split_while(history, &(&1.sampled_at_ms > since)),
         true <- (now - latest.sampled_at_ms) in 0..@max_gap_ms,
         true <- (since - baseline.sampled_at_ms) in 0..@max_gap_ms do
      classify(recent, baseline, since)
    else
      _ -> :unknown
    end
  end

  def pressure(_worker_host, _elapsed_ms), do: :unknown

  @impl true
  def init(opts) do
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    state = {Keyword.get(opts, :proc_root, "/proc"), Keyword.get(opts, :cgroup_root, "/sys/fs/cgroup"), Keyword.get(opts, :browser_lock, @browser_lock)}
    {:ok, state, {:continue, :sample}}
  end

  @impl true
  def handle_continue(:sample, state), do: handle_info(:sample, state)

  @impl true
  def handle_info(:sample, {proc_root, cgroup_root, browser_lock} = state) do
    history =
      case read_sample(proc_root, cgroup_root, browser_lock) do
        {:ok, sample} -> [sample | Enum.take(samples(), @history_size - 1)]
        :unavailable -> []
      end

    :ets.insert(__MODULE__, {:samples, history})
    Process.send_after(self(), :sample, @interval_ms)
    {:noreply, state}
  end

  defp samples do
    :ets.lookup_element(__MODULE__, :samples, 2, [])
  rescue
    ArgumentError -> []
  end

  defp classify(recent, baseline, since) do
    recent
    |> Enum.zip(tl(recent) ++ [baseline])
    |> Enum.reduce_while({0, 0, 0, 0}, fn {sample, previous}, {measured_ms, memory_us, io_us, oom} = totals ->
      case interval(sample, previous) do
        nil ->
          {:halt, :unknown}

        delta when previous.sampled_at_ms >= since ->
          reclaimed_us = if delta.memory_events_high > 0, do: delta.memory_some_us, else: 0
          {:cont, {measured_ms + delta.interval_ms, memory_us + reclaimed_us, io_us + delta.io_full_us, oom + delta.oom_kill}}

        _ ->
          {:cont, totals}
      end
    end)
    |> case do
      {measured_ms, memory_us, io_us, oom} when measured_ms > 0 ->
        if oom > 0 or memory_us * 100 >= measured_ms * 1_000 * @memory_stall_percent or io_us * 100 >= measured_ms * 1_000 * @io_stall_percent do
          :pressured
        else
          :clear
        end

      _ ->
        :unknown
    end
  end

  defp interval(sample, previous) do
    with %{sampled_at_ms: previous_ms, cgroup: cgroup, runtime_cgroup: runtime_cgroup} <- previous,
         %{cgroup: ^cgroup, runtime_cgroup: ^runtime_cgroup} <- sample,
         true <- Map.get(sample, :cgroup_inode) == Map.get(previous, :cgroup_inode),
         true <- (sample.sampled_at_ms - previous_ms) in 1..@max_gap_ms do
      delta = Map.new(@counters, &{&1, Map.fetch!(sample, &1) - Map.fetch!(previous, &1)})

      if Enum.all?(delta, fn {_key, count} -> count >= 0 end) do
        Map.put(delta, :interval_ms, sample.sampled_at_ms - previous_ms)
      end
    else
      _ -> nil
    end
  end

  defp read_sample(proc_root, cgroup_root, browser_lock) do
    started = System.monotonic_time(:millisecond)

    with {:ok, runtime_cgroup} <- runtime_cgroup(proc_root),
         {cgroup, directory, high, max} <- limiting_cgroup(runtime_cgroup, cgroup_root),
         {:ok, %{inode: inode}} <- File.stat(directory),
         {:ok, current} <- read_number(directory, "memory.current"),
         {:ok, swap} <- read_number(directory, "memory.swap.current"),
         {:ok, events} <- read_fields(directory, "memory.events"),
         %{"high" => high_events, "oom_kill" => oom_kill} <- events,
         {:ok, memory_some} <- read_psi(directory, "memory.pressure", "some"),
         {:ok, io_full} <- read_psi(directory, "io.pressure", "full"),
         {:ok, meminfo} <- read_fields(proc_root, "meminfo"),
         %{"MemAvailable:" => available_kb, "SwapTotal:" => swap_total_kb, "SwapFree:" => swap_free_kb} <- meminfo,
         true <- swap_free_kb <= swap_total_kb,
         {:ok, host} <- :inet.gethostname(),
         lock_state = browser_lock_state(proc_root, browser_lock),
         now = System.monotonic_time(:millisecond),
         true <- now - started <= @interval_ms do
      {:ok,
       %{
         source: :local,
         host: List.to_string(host),
         sampled_at_ms: now,
         runtime_cgroup: runtime_cgroup,
         cgroup: cgroup,
         cgroup_inode: inode,
         memory_current_bytes: current,
         memory_high_bytes: high,
         memory_max_bytes: max,
         cgroup_swap_bytes: swap,
         host_memory_available_bytes: available_kb * 1_024,
         host_swap_total_bytes: swap_total_kb * 1_024,
         host_swap_used_bytes: (swap_total_kb - swap_free_kb) * 1_024,
         memory_events_high: high_events,
         oom_kill: oom_kill,
         memory_some_us: memory_some,
         io_full_us: io_full,
         browser_lock: lock_state
       }}
    else
      _ -> :unavailable
    end
  end

  defp runtime_cgroup(proc_root) do
    with {:ok, text} <- File.read(Path.join(proc_root, "self/cgroup")),
         [_, path] <- Regex.run(~r/^0::(\/[^\r\n]*)$/m, text),
         false <- Enum.any?(String.split(path, "/"), &(&1 in [".", ".."])) do
      {:ok, path}
    end
  end

  defp limiting_cgroup(path, root) do
    # Workers are sibling units; the inherited limit may live above the runtime unit.
    ancestors = path |> String.split("/", trim: true) |> Enum.scan("", &(&2 <> "/" <> &1))

    candidates =
      for cgroup <- ["/" | ancestors],
          directory = Path.join(root, String.trim_leading(cgroup, "/")),
          {:ok, high} <- [read_limit(directory, "memory.high")],
          {:ok, max} <- [read_limit(directory, "memory.max")],
          do: {cgroup, directory, high, max}

    Enum.min_by(candidates, fn {_, _, high, max} -> min(high, max) end, fn -> nil end)
  end

  defp read_limit(directory, file) do
    case read_number(directory, file) do
      {:error, :unlimited} -> {:ok, :max}
      result -> result
    end
  end

  defp read_number(directory, file) do
    with {:ok, value} <- File.read(Path.join(directory, file)) do
      case String.trim(value) do
        "max" -> {:error, :unlimited}
        value -> number(value)
      end
    end
  end

  defp read_fields(directory, file) do
    with {:ok, text} <- File.read(Path.join(directory, file)) do
      {:ok,
       for(
         line <- String.split(text, "\n"),
         [key, value | _] <- [String.split(line)],
         {:ok, count} <- [number(value)],
         into: %{},
         do: {key, count}
       )}
    end
  end

  defp read_psi(directory, file, metric) do
    with {:ok, text} <- File.read(Path.join(directory, file)),
         [_, value] <- Regex.run(~r/^#{metric} [^\n]*\btotal=(\d+)$/m, text) do
      number(value)
    end
  end

  defp browser_lock_state(proc_root, path) do
    with {:ok, %File.Stat{type: :regular, major_device: device, inode: inode}} <- File.stat(path),
         {:ok, {:ok, locks}} <- File.open(Path.join(proc_root, "locks"), [:read, :binary], &read_locks/1) do
      if Enum.any?(String.split(locks, "\n"), &owns_lock?(&1, device, inode)), do: :locked, else: :unlocked
    else
      _ -> :unknown
    end
  end

  defp read_locks(file) do
    case IO.binread(file, @max_locks_bytes + 1) do
      :eof -> {:ok, ""}
      text when is_binary(text) and byte_size(text) <= @max_locks_bytes -> {:ok, text}
      _ -> :unavailable
    end
  end

  defp owns_lock?(line, device, inode) do
    with [_, "FLOCK", "ADVISORY", _, _, identity | _] <- String.split(line),
         [major, minor, file_inode] <- String.split(identity, ":"),
         {major, ""} <- Integer.parse(major, 16),
         {minor, ""} <- Integer.parse(minor, 16),
         {^inode, ""} <- Integer.parse(file_inode) do
      # Linux File.Stat reports the encoded dev_t in major_device.
      encoded = (major &&& 0xFFF) <<< 8 ||| (major &&& 0xFFFFF000) <<< 32 ||| (minor &&& 0xFF) ||| (minor &&& 0xFFFFFF00) <<< 12
      encoded == device
    else
      _ -> false
    end
  end

  defp number(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> :error
    end
  end
end
