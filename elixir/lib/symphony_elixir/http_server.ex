defmodule SymphonyElixir.HttpServer do
  @moduledoc """
  Compatibility facade that starts the Phoenix observability endpoint when enabled.
  """

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.Endpoint

  @secret_key_bytes 48

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case Keyword.get(opts, :mode, :legacy) do
      :profiles -> start_profiles(opts)
      :legacy -> start_legacy(opts)
    end
  end

  defp start_profiles(opts) do
    port = Keyword.get_lazy(opts, :port, fn -> Application.get_env(:symphony_elixir, :server_port_override, 4000) end)
    config = Application.get_env(:symphony_elixir, Endpoint, [])

    start_endpoint(
      server: true,
      http: [ip: {127, 0, 0, 1}, port: port],
      https: false,
      observability_mode: :profiles,
      snapshot_timeout_ms: Keyword.get(opts, :snapshot_timeout_ms, 500),
      secret_key_base: configured_secret(Keyword.get(config, :secret_key_base))
    )
  end

  defp start_legacy(opts) do
    case Keyword.get_lazy(opts, :port, &Config.server_port/0) do
      port when is_integer(port) and port >= 0 ->
        host = Keyword.get_lazy(opts, :host, fn -> Config.settings!().server.host end)
        orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
        snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

        with {:ok, ip} <- parse_host(host) do
          start_endpoint(
            server: true,
            http: [ip: ip, port: port],
            url: [host: normalize_host(host)],
            observability_mode: :legacy,
            orchestrator: orchestrator,
            snapshot_timeout_ms: snapshot_timeout_ms,
            secret_key_base: secret_key_base()
          )
        end

      _ ->
        :ignore
    end
  end

  defp start_endpoint(opts) do
    config = :symphony_elixir |> Application.get_env(Endpoint, []) |> Keyword.merge(opts)
    Application.put_env(:symphony_elixir, Endpoint, config)
    Endpoint.start_link()
  end

  @spec bound_port(term()) :: non_neg_integer() | nil
  def bound_port(_server \\ __MODULE__) do
    case Bandit.PhoenixAdapter.server_info(Endpoint, :http) do
      {:ok, {_ip, port}} when is_integer(port) -> port
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end

  defp normalize_host(host) when host in ["", nil], do: "127.0.0.1"
  defp normalize_host(host) when is_binary(host), do: host
  defp normalize_host(host), do: to_string(host)

  @default_secret String.duplicate("s", 64)

  defp configured_secret(key) when is_binary(key) and key != @default_secret, do: key
  defp configured_secret(_key), do: secret_key_base()

  defp secret_key_base do
    Base.encode64(:crypto.strong_rand_bytes(@secret_key_bytes), padding: false)
  end
end
