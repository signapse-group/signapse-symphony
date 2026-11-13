defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Profile, RuntimeControl, WorkflowUpdate}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter, ProfileObservability}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    mode = ProfileObservability.mode()

    socket =
      assign(socket,
        mode: mode,
        profile: nil,
        profile_ids: if(mode == :profiles, do: Profile.ids(), else: []),
        profile_actions: %{},
        service_health: nil,
        profile_health: [],
        selection_error: nil,
        payload: %{},
        workflow_updating: false,
        workflow_update_message: nil,
        now: DateTime.utc_now()
      )

    if connected?(socket) do
      :ok = if mode == :profiles, do: ObservabilityPubSub.subscribe_profiles(), else: ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
      if mode == :profiles, do: schedule_overview_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{mode: :profiles}} = socket) do
    id = Map.get(params, "profile_id", List.first(socket.assigns.profile_ids))

    socket =
      if ProfileObservability.known?(id) do
        socket |> assign(profile: id, selection_error: nil) |> refresh_payload()
      else
        assign(socket, profile: nil, payload: %{}, selection_error: "Profile not found.")
      end

    {:noreply, refresh_overview(socket)}
  end

  def handle_params(%{"profile_id" => _id}, _uri, socket) do
    {:noreply, assign(socket, selection_error: "Profile not found.")}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(selection_error: nil) |> refresh_payload()}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, refresh_payload(socket)}
  end

  def handle_info(:overview_tick, socket) do
    schedule_overview_tick()
    {:noreply, refresh_overview(socket)}
  end

  def handle_info(:observability_updated, %{assigns: %{mode: :legacy}} = socket) do
    {:noreply, refresh_payload(socket)}
  end

  def handle_info({:observability_updated, id}, %{assigns: %{profile: id, mode: :profiles}} = socket) do
    {:noreply, refresh_payload(socket)}
  end

  def handle_info({:observability_updated, _id}, socket), do: {:noreply, socket}

  @impl true
  def handle_event(event, %{"profile" => id} = params, %{assigns: %{mode: :profiles, profile: id}} = socket)
      when event in ["pause_profile", "resume_profile", "activate_profile"] do
    if ProfileObservability.known?(id) and get_in(socket.assigns.profile_actions, [id, :pending]) != true do
      revision = Map.get(params, "revision")
      operation = profile_operation(event)

      {:noreply,
       socket
       |> assign_profile_action(id, pending: true, message: nil)
       |> start_async({:profile_action, id}, fn -> ProfileObservability.perform(id, operation, revision) end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(_event, _params, %{assigns: %{mode: :profiles}} = socket), do: {:noreply, socket}

  def handle_event(_event, _params, %{assigns: %{selection_error: error}} = socket) when is_binary(error), do: {:noreply, socket}

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
  def handle_async({:profile_action, id}, result, socket) do
    message =
      case result do
        {:ok, message} -> message
        {:exit, _reason} -> "The action was interrupted. Check this profile before retrying."
      end

    :ok = ObservabilityPubSub.broadcast_update(id)
    {:noreply, assign_profile_action(socket, id, pending: false, message: message)}
  end

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

      <.profile_navigation :if={@mode == :profiles} ids={@profile_ids} current={@profile} health={@service_health} states={@profile_health} />

      <section :if={@selection_error} class="error-card" role="alert">
        <h2 class="error-title"><%= @selection_error %></h2>
      </section>

      <div :if={!@selection_error} class="profile-panel" id="profile-panel" aria-labelledby={@profile && "tab-#{@profile}"}>
      <.profile_workflow :if={@mode == :profiles} id={@profile} payload={@payload} action={@profile_actions[@profile] || %{}} />

      <section :if={@mode == :legacy} class="section-card">
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
            <p :if={@mode == :legacy} class="section-copy">Pause or resume Codex work across BE, FE and landing.</p>
            <p :if={@profile} class="section-copy">
              Desired state: <%= @payload.runtime_control[:desired_state] %>
            </p>
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
        <p :if={admission_quota_message(@payload)} id="admission-quota-status" class="runtime-control-reason" role="status">
          <%= admission_quota_message(@payload) %>
        </p>
        <p :if={@payload[:runtime_control] && runtime_control_mode(@payload.runtime_control) == :pausing && @payload.runtime_control.active_turns > 0} class="runtime-control-reason">
          <%= if @profile do %>
            Waiting for <%= @payload.runtime_control.active_turns %> active worker(s) to finish.
          <% else %>
            Waiting for <%= @payload.runtime_control.active_turns %> active Codex turn(s) to finish.
          <% end %>
        </p>

        <div class="runtime-control-actions">
          <button
            :if={runtime_control_mode(@payload[:runtime_control]) in [:running, :checking_quota]}
            id={if(@profile, do: "pause-profile")}
            phx-click={if(@profile, do: "pause_profile", else: "pause_all")}
            phx-value-profile={@profile}
            disabled={get_in(@profile_actions, [@profile, :pending]) == true}
          >
            <%= if @profile, do: "Pause #{ProfileObservability.label(@profile)}", else: "Pause all" %>
          </button>
          <button
            :if={runtime_control_mode(@payload[:runtime_control]) == :paused}
            id={if(@profile, do: "resume-profile")}
            class="secondary"
            phx-click={if(@profile, do: "resume_profile", else: "resume_all")}
            phx-value-profile={@profile}
            disabled={get_in(@profile_actions, [@profile, :pending]) == true or (is_binary(@profile) and @payload.health != "healthy")}
          >
            Check quota and resume<%= if @profile, do: " #{ProfileObservability.label(@profile)}" %>
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
            <p class="metric-label"><%= waiting_label(@payload) %></p>
            <p id="waiting-count" class="metric-value numeric"><%= @payload.counts.waiting || "n/a" %></p>
            <p class="metric-detail">Eligible tasks from the latest successful tracker poll.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail"><%= if @profile, do: "Issues waiting for operator input, approval, or session inspection.", else: "Issues paused for operator input or approval." %></p>
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

        <section id="waiting-queue" class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title"><%= waiting_label(@payload) %></h2>
              <p class="section-copy">Eligible tasks cached from the latest successful tracker poll, in dispatch order.</p>
              <p :if={@payload.waiting_updated_at} class="section-copy">
                Last successful poll: <span class="mono numeric"><%= @payload.waiting_updated_at %></span>
              </p>
            </div>
          </div>

          <%= cond do %>
            <% is_nil(@payload.counts.waiting) -> %>
              <p class="empty-state">Waiting tasks unavailable until a successful tracker poll.</p>
            <% @payload.waiting == [] -> %>
              <p class="empty-state"><%= if admission_quota_message(@payload), do: "No new eligible tasks waiting for provider quota.", else: "No eligible tasks waiting for slots." %></p>
            <% true -> %>
              <div class="table-wrap">
                <table class="data-table">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>Title</th>
                      <th>State</th>
                      <th>Priority</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.waiting}>
                      <td><.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} /></td>
                      <td><%= entry.title %></td>
                      <td><span class={state_badge_class(entry.state)}><%= entry.state %></span></td>
                      <td class="numeric"><%= entry.priority || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
          <% end %>
        </section>

        <section :if={@mode == :legacy} class="section-card">
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
                        <a class="issue-link" href={ProfileObservability.issue_path(@profile, entry.issue_identifier)}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                      <span :if={entry[:handoff_error]} class="status-badge runtime-control-paused">Operator inspection required</span>
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

        <section id="blocked-sessions" class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy"><%= if @profile, do: "Issues waiting for operator input, approval, or confirmation that a session stopped.", else: "Issues paused because Codex requested operator input or approval." %></p>
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
                        <a class="issue-link" href={ProfileObservability.issue_path(@profile, entry.issue_identifier)}>JSON details</a>
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
                        <a class="issue-link" href={ProfileObservability.issue_path(@profile, entry.issue_identifier)}>JSON details</a>
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
      </div>
    </section>
    """
  end

  attr(:ids, :list, required: true)
  attr(:current, :string, default: nil)
  attr(:health, :string, default: nil)
  attr(:states, :list, required: true)

  defp profile_navigation(assigns) do
    ~H"""
    <nav class="profile-tabs" aria-label="Symphony profiles">
      <.link
        :for={id <- @ids}
        id={"tab-#{id}"}
        patch={"/profiles/#{id}"}
        aria-current={if id == @current, do: "page"}
      >
        <%= ProfileObservability.label(id) %>
      </.link>
    </nav>
    <section :if={@health} class="section-card" id="service-health" aria-label="Service health">
      <strong><%= service_health_label(@health) %></strong>
      <ul :if={@health != "healthy"} class="profile-unavailable-list">
        <li :for={state <- Enum.reject(@states, &(&1.health == "healthy"))}>
          <.link patch={"/profiles/#{state.profile_id}"}><%= ProfileObservability.label(state.profile_id) %></.link>
          <%= humanize_code(state.reason) %>
        </li>
      </ul>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:payload, :map, required: true)
  attr(:action, :map, required: true)

  defp profile_workflow(assigns) do
    ~H"""
    <section id={"workflow-#{@id}"} class="section-card">
      <div class="section-header">
        <div>
          <h2 class="section-title"><%= ProfileObservability.label(@id) %> workflow</h2>
          <p id="profile-health" class="section-copy">
            <%= if @payload.health == "healthy", do: "Ready", else: "Unavailable" %>
            <span :if={@payload.reason}>· <%= humanize_code(@payload.reason) %></span>
          </p>
        </div>
        <p class="section-copy">Worker limit <strong id="profile-cap"><%= @payload.max_concurrent_agents || "—" %></strong></p>
      </div>
      <dl class="profile-revisions">
        <dt>Deployment workflow</dt>
        <dd id="workflow-revision" class="mono"><%= @payload.workflow_revision || "Unavailable" %></dd>
        <dt>Active instructions</dt>
        <dd id="instructions-revision" class="mono"><%= @payload.instructions_revision || "Unavailable" %></dd>
      </dl>
      <p :if={@payload[:workflow_reload_error]} class="runtime-control-reason">
        Workflow reload failed: <%= humanize_code(@payload.workflow_reload_error) %>
      </p>
      <p :if={@payload[:browser_lock] == "locked"} class="section-copy">
        Shared browser test slot is occupied.
      </p>
      <form id={"activate-#{@id}"} class="profile-update-form" phx-submit="activate_profile">
        <input type="hidden" name="profile" value={@id} />
        <label for={"revision-#{@id}"}>Staged instructions revision</label>
        <input type="text" id={"revision-#{@id}"} name="revision" required maxlength="128" spellcheck="false" />
        <button type="submit" disabled={@action[:pending] == true}>Update workflow</button>
      </form>
      <p :if={@action[:message]} id="profile-action-result" role="status"><%= @action.message %></p>
    </section>
    """
  end

  defp humanize_code(code), do: code |> String.replace("_", " ") |> String.capitalize()

  defp service_health_label("healthy"), do: "All profiles operational"
  defp service_health_label("partial"), do: "Service partially operational"
  defp service_health_label(_health), do: "Service unavailable"

  defp waiting_label(payload), do: if(admission_quota_message(payload), do: "Waiting for provider quota", else: "Waiting for slots")

  defp admission_quota_message(%{admission_error: "provider_quota_exhausted", runtime_control: %{mode: :running}}),
    do: "Provider quota is exhausted. New work waits for the next quota check."

  defp admission_quota_message(%{admission_error: "provider_quota_unavailable", runtime_control: %{mode: :running}}),
    do: "Provider quota could not be verified. New work waits for the next quota check."

  defp admission_quota_message(_payload), do: nil

  defp profile_operation("pause_profile"), do: :pause
  defp profile_operation("resume_profile"), do: :resume
  defp profile_operation("activate_profile"), do: :activate

  defp assign_profile_action(socket, id, result) do
    assign(socket, :profile_actions, Map.put(socket.assigns.profile_actions, id, Map.new(result)))
  end

  defp refresh_payload(%{assigns: %{selection_error: error}} = socket) when is_binary(error), do: socket

  defp refresh_payload(%{assigns: %{profile: id}} = socket) when is_binary(id) do
    assign(socket, payload: ProfileObservability.state(id), now: DateTime.utc_now())
  end

  defp refresh_payload(socket), do: assign(socket, payload: load_payload(), now: DateTime.utc_now())

  defp refresh_overview(socket) do
    overview = ProfileObservability.overview()
    assign(socket, service_health: overview.health, profile_health: overview.profiles)
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

  defp schedule_overview_tick, do: Process.send_after(self(), :overview_tick, 5_000)

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
