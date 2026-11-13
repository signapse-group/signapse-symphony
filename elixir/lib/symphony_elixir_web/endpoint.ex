defmodule SymphonyElixirWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for Symphony's optional observability UI and API.
  """

  use Phoenix.Endpoint, otp_app: :symphony_elixir

  @session_options [
    store: :cookie,
    key: "_symphony_elixir_key",
    signing_salt: "symphony-session"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  @session Plug.Session.init(@session_options)
  @secure_session Plug.Session.init(Keyword.put(@session_options, :secure, true))

  plug(:session)
  plug(SymphonyElixirWeb.Router)

  defp session(conn, _opts) do
    if config(:observability_mode) == :profiles and config(:url)[:scheme] == "https" do
      Plug.Session.call(conn, @secure_session)
    else
      Plug.Session.call(conn, @session)
    end
  end
end
