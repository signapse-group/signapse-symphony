defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter, ProfileObservability}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    case ProfileObservability.mode() do
      :profiles -> json(conn, ProfileObservability.overview())
      :legacy -> json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    in_legacy(conn, fn ->
      issue_response(conn, Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()))
    end)
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    in_legacy(conn, fn -> refresh_response(conn, Presenter.refresh_payload(orchestrator())) end)
  end

  @spec profile_state(Conn.t(), map()) :: Conn.t()
  def profile_state(conn, %{"profile_id" => id}) do
    with_profile(conn, id, fn -> json(conn, ProfileObservability.state(id)) end)
  end

  @spec profile_issue(Conn.t(), map()) :: Conn.t()
  def profile_issue(conn, %{"profile_id" => id, "issue_identifier" => identifier}) do
    with_profile(conn, id, fn -> issue_response(conn, ProfileObservability.issue(id, identifier)) end)
  end

  @spec profile_refresh(Conn.t(), map()) :: Conn.t()
  def profile_refresh(conn, %{"profile_id" => id}) do
    with_profile(conn, id, fn -> refresh_response(conn, ProfileObservability.refresh(id)) end)
  end

  defp issue_response(conn, {:ok, payload}), do: json(conn, payload)

  defp issue_response(conn, {:error, :issue_not_found}) do
    error_response(conn, 404, "issue_not_found", "Issue not found")
  end

  defp refresh_response(conn, {:ok, payload}), do: conn |> put_status(202) |> json(payload)

  defp refresh_response(conn, {:error, :unavailable}) do
    error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
  end

  defp in_legacy(conn, action) do
    if ProfileObservability.mode() == :legacy,
      do: action.(),
      else: error_response(conn, 400, "profile_required", "Select a profile")
  end

  defp with_profile(conn, id, action) do
    if ProfileObservability.known?(id),
      do: action.(),
      else: error_response(conn, 404, "unknown_profile", "Profile not found")
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
