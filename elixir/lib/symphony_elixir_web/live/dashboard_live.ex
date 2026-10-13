defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{RuntimeControl, WorkflowUpdate}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:workflow_updating, false)
      |> assign(:workflow_update_message, nil)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("update_workflow", _params, %{assigns: %{workflow_updating: true}} = socket), do: {:noreply, socket}

  def handle_event("update_workflow", _params, socket) do
    server = orchestrator()

    {:noreply,
     socket
     |> assign(:workflow_updating, true)
     |> assign(:workflow_update_message, nil)
     |> start_async(:update_workflow, fn -> WorkflowUpdate.update(server) end)}
  end

  def handle_event("pause_all", _params, socket) do
    case RuntimeControl.pause("Paused by operator from the dashboard", "manual", runtime_control()) do
      {:ok, _status} ->
        :ok = ObservabilityPubSub.broadcast_update()
        {:noreply, assign(socket, :payload, load_payload())}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not pause runtime: #{inspect(reason)}")
         |> assign(:payload, load_payload())}
    end
  end

  def handle_event("resume_all", _params, socket) do
    case RuntimeControl.resume(runtime_control()) do
      {:ok, _status} ->
        :ok = ObservabilityPubSub.broadcast_update()
        {:noreply, assign(socket, :payload, load_payload())}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not check Codex quota: #{inspect(reason)}")
         |> assign(:payload, load_payload())}
    end
  end

  @impl true
  def handle_async(:update_workflow, {:ok, {_status, message}}, socket) do
    {:noreply, assign(socket, workflow_updating: false, workflow_update_message: message)}
  end

  def handle_async(:update_workflow, {:exit, _reason}, socket) do
    {:noreply, assign(socket, workflow_updating: false, workflow_update_message: "Update interrupted. Check repository state before retrying.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Workflow</h2>
            <p class="section-copy">Update this service's repository from main. Existing issue workspaces are kept.</p>
          </div>
          <button id="update-workflow" phx-click="update_workflow" disabled={@workflow_updating}>
            <%= if @workflow_updating, do: "Updating…", else: "Update workflow" %>
          </button>
        </div>
        <p :if={@workflow_update_message} role="status"><%= @workflow_update_message %></p>
      </section>

      <p :if={Phoenix.Flash.get(@flash, :error)} role="alert" class="error-card">
        <%= Phoenix.Flash.get(@flash, :error) %>
      </p>

      <section :if={@payload[:runtime_control] && Map.get(@payload.runtime_control, :enabled, true)} class="section-card runtime-control-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Runtime control</h2>
            <p class="section-copy">Pause or resume Codex work across BE, FE and landing.</p>
          </div>
          <strong class={runtime_control_badge_class(@payload[:runtime_control])}>
            <%= runtime_control_label(@payload[:runtime_control]) %>
          </strong>
        </div>

        <p :if={@payload[:runtime_control] && @payload.runtime_control[:reason]} class="runtime-control-reason">
          <%= @payload.runtime_control.reason %>
        </p>
        <p :if={@payload.runtime_control[:changed_at]} class="runtime-control-reason">
          Changed: <%= @payload.runtime_control.changed_at %> · Source: <%= @payload.runtime_control[:source] %>
        </p>
        <p :for={{service, health} <- Map.get(@payload.runtime_control, :services, %{})} class="runtime-control-reason">
          <%= service %>: <%= if health.status == :online, do: "Online", else: "Unknown / unavailable" %>
        </p>
        <p :if={@payload[:runtime_control] && @payload.runtime_control[:database_error]} class="runtime-control-reason">
          State store error: <%= @payload.runtime_control.database_error %>
        </p>
        <p :if={@payload[:runtime_control] && @payload.runtime_control[:quota_summary]} class="runtime-control-reason">
          Last quota check: <%= @payload.runtime_control.quota_summary %>
          <span :if={@payload.runtime_control[:quota_checked_at]}> · <%= @payload.runtime_control.quota_checked_at %></span>
        </p>
        <p :if={@payload[:runtime_control] && runtime_control_mode(@payload.runtime_control) == :pausing && @payload.runtime_control.active_turns > 0} class="runtime-control-reason">
          Waiting for <%= @payload.runtime_control.active_turns %> active Codex turn(s) to finish.
        </p>

        <div class="runtime-control-actions">
          <button :if={runtime_control_mode(@payload[:runtime_control]) in [:running, :checking_quota]} phx-click="pause_all">
            Pause all
          </button>
          <button :if={runtime_control_mode(@payload[:runtime_control]) == :paused} class="secondary" phx-click="resume_all">
            Check quota and resume
          </button>
          <button :if={runtime_control_mode(@payload[:runtime_control]) in [:pausing, :checking_quota, :unknown]} disabled>
            <%= case runtime_control_mode(@payload[:runtime_control]) do %>
              <% :checking_quota -> %>Checking quota…
              <% :pausing -> %>Pausing…
              <% _ -> %>Control unavailable
            <% end %>
          </button>
        </div>
      </section>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    payload = Presenter.state_payload(orchestrator(), snapshot_timeout_ms())

    if is_nil(payload[:runtime_control]) or not is_nil(Endpoint.config(:runtime_control)) do
      control =
        case RuntimeControl.status(runtime_control()) do
          {:ok, status} ->
            status

          {:error, reason} ->
            %{
              mode: :unknown,
              reason: "Runtime control unavailable",
              active_turns: 0,
              quota_summary: nil,
              quota_checked_at: nil,
              database_error: inspect(reason)
            }
        end

      Map.put(payload, :runtime_control, control)
    else
      payload
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp runtime_control, do: Endpoint.config(:runtime_control) || RuntimeControl

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp runtime_control_mode(%{mode: mode}), do: mode
  defp runtime_control_mode(%{"mode" => "running"}), do: :running
  defp runtime_control_mode(%{"mode" => "pausing"}), do: :pausing
  defp runtime_control_mode(%{"mode" => "paused"}), do: :paused
  defp runtime_control_mode(%{"mode" => "checking_quota"}), do: :checking_quota
  defp runtime_control_mode(_control), do: :unknown

  defp runtime_control_label(control) do
    case runtime_control_mode(control) do
      :running -> "Running"
      :pausing -> "Pausing"
      :paused -> paused_label(control)
      :checking_quota -> "Checking quota"
      _ -> "Control unavailable"
    end
  end

  defp paused_label(%{source: "manual"}), do: "Paused manually"
  defp paused_label(%{source: source}) when source in ["quota", "quota_check"], do: "Waiting for quota"
  defp paused_label(_control), do: "Paused"

  defp runtime_control_badge_class(control) do
    case runtime_control_mode(control) do
      :running -> "status-badge runtime-control-running"
      :paused -> "status-badge runtime-control-paused"
      _ -> "status-badge status-badge-warning"
    end
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
