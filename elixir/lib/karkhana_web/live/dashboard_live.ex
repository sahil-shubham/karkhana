defmodule KarkhanaWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Karkhana.
  """

  use Phoenix.LiveView, layout: {KarkhanaWeb.Layouts, :app}

  alias KarkhanaWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
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
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Karkhana
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health.
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
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.agent_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.agent_totals.input_tokens) %> / Out <%= format_int(@payload.agent_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total agent runtime across completed and active sessions.</p>
          </article>
        </section>

        <%= if Map.get(@payload, :methodology) do %>
          <% m = @payload.methodology %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Methodology</h2>
                <p class="section-copy">Mode distribution, gate pass rates, and config changes.</p>
              </div>
            </div>

            <div class="metric-grid">
              <article class="metric-card">
                <p class="metric-label">Total runs</p>
                <p class="metric-value numeric"><%= m.total || 0 %></p>
              </article>

              <%= for {mode, count} <- Map.get(m, :by_mode, %{}) do %>
                <article class="metric-card">
                  <p class="metric-label"><%= mode || "default" %></p>
                  <p class="metric-value numeric"><%= count %></p>
                  <p class="metric-detail">runs</p>
                </article>
              <% end %>
            </div>

            <%= if Map.get(m, :gate_pass_rate, %{}) != %{} do %>
              <div class="metric-grid" style="margin-top: 1rem;">
                <%= for {gate, rate} <- Map.get(m, :gate_pass_rate, %{}) do %>
                  <article class="metric-card">
                    <p class="metric-label"><%= gate %></p>
                    <p class="metric-value numeric"><%= Float.round((rate || 0) * 100, 0) %>%%</p>
                    <p class="metric-detail">pass rate</p>
                  </article>
                <% end %>
              </div>
            <% end %>

            <%= if Map.get(m, :avg_cost_by_mode, %{}) != %{} do %>
              <div class="metric-grid" style="margin-top: 1rem;">
                <%= for {mode, cost} <- Map.get(m, :avg_cost_by_mode, %{}) do %>
                  <article class="metric-card">
                    <p class="metric-label"><%= mode || "default" %></p>
                    <p class="metric-value numeric">$<%= :erlang.float_to_binary((cost || 0.0) + 0.0, decimals: 2) %></p>
                    <p class="metric-detail">avg cost</p>
                  </article>
                <% end %>
              </div>
            <% end %>

            <%= if Map.get(m, :recent_config_changes, []) != [] do %>
              <div style="margin-top: 1rem;">
                <p class="metric-label" style="margin-bottom: 0.5rem;">Config changes</p>
                <div class="table-wrap">
                  <table class="data-table" style="min-width: 500px;">
                    <thead>
                      <tr>
                        <th>From</th>
                        <th>To</th>
                        <th>Files</th>
                        <th>At</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={c <- Map.get(m, :recent_config_changes, [])}>
                        <td class="mono"><%= short_hash(c.previous_hash) %></td>
                        <td class="mono"><%= short_hash(c.config_hash) %></td>
                        <td><%= Enum.join(c.changed_files || [], ", ") %></td>
                        <td class="mono"><%= c.inserted_at %></td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            <% end %>
          </section>
        <% end %>

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
            <div :for={entry <- @payload.running} class="section-card" style="margin-top: 0.75rem; padding: 1rem;">
              <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 1rem; flex-wrap: wrap;">
                <div>
                  <span class="issue-id" style="font-size: 1.1rem;"><%= entry.issue_identifier %></span>
                  <span class={state_badge_class(entry.state)} style="margin-left: 0.5rem;"><%= entry.state %></span>
                  <%= if Map.get(entry, :mode) do %>
                    <span class="mode-badge" style="margin-left: 0.25rem;"><%= entry.mode %></span>
                  <% end %>
                </div>
                <div class="numeric" style="text-align: right;">
                  <span><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></span>
                  <%= if Map.get(entry, :cost_usd, 0.0) > 0 do %>
                    <span class="muted" style="margin-left: 0.75rem;">$<%= :erlang.float_to_binary((entry.cost_usd || 0.0) + 0.0, decimals: 2) %></span>
                  <% end %>
                </div>
              </div>

              <div style="margin-top: 0.75rem; padding: 0.5rem 0.75rem; background: var(--surface-raised, #1a1a2e); border-radius: 6px; font-size: 0.875rem;">
                <span style="opacity: 0.7;"><%= entry.last_event || "waiting" %></span>
                <span style="margin-left: 0.5rem;"><%= entry.last_message || "No activity yet" %></span>
              </div>

              <div style="margin-top: 0.5rem; display: flex; gap: 1.5rem; flex-wrap: wrap; font-size: 0.8rem;" class="muted">
                <span>Tokens: <span class="numeric"><%= format_int(entry.tokens.total_tokens) %></span></span>
                <span>In: <span class="numeric"><%= format_int(entry.tokens.input_tokens) %></span></span>
                <span>Out: <span class="numeric"><%= format_int(entry.tokens.output_tokens) %></span></span>
                <%= if Map.get(entry.tokens, :cache_read, 0) > 0 do %>
                  <span>Cache: <span class="numeric"><%= format_int(entry.tokens.cache_read) %></span></span>
                <% end %>
                <%= if entry.session_id do %>
                  <span>Session: <span class="mono"><%= String.slice(entry.session_id, 0..7) %></span></span>
                <% end %>
                <%= if Map.get(entry, :sandbox_id) do %>
                  <span>Sandbox: <span class="mono"><%= String.slice(entry.sandbox_id, 0..7) %></span></span>
                <% end %>
              </div>
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
                        <span class="issue-id"><%= entry.issue_identifier %></span>
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

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Recent runs</h2>
              <p class="section-copy">Completed dispatch attempts with cost and outcome.</p>
            </div>
          </div>

          <%= if Map.get(@payload, :completed_runs, []) == [] do %>
            <p class="empty-state">No completed runs yet.</p>
          <% else %>
            <div class="table-wrap" style="max-height: 400px; overflow-y: auto;">
              <table class="data-table" style="min-width: 800px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Mode</th>
                    <th>Outcome</th>
                    <th>Gate</th>
                    <th>Cost</th>
                    <th>Duration</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={run <- Map.get(@payload, :completed_runs, [])}>
                    <td>
                      <span class="issue-id"><%= run.issue_identifier %></span>
                    </td>
                    <td>
                      <span class="mode-badge"><%= Map.get(run, :mode) || "—" %></span>
                    </td>
                    <td>
                      <span class={outcome_badge_class(run.outcome)}>
                        <%= run.outcome %>
                      </span>
                    </td>
                    <td>
                      <%= case Map.get(run, :gate_result) do %>
                        <% "pass" -> %><span class="status-badge status-badge-live">✓</span>
                        <% "fail" -> %><span class="status-badge status-badge-offline">✗</span>
                        <% _ -> %><span class="muted">—</span>
                      <% end %>
                    </td>
                    <td class="numeric">$<%= :erlang.float_to_binary(run.cost_usd || 0.0, decimals: 2) %></td>
                    <td class="numeric"><%= format_duration(run.duration_seconds) %></td>
                    <td>
                      <%= if run.error_message do %>
                        <span class="error-text" title={Map.get(run, :error_raw) || run.error_message} style="font-size: 0.8rem; color: var(--danger, #eb5757);">
                          <%= String.slice(run.error_message, 0, 120) %>
                        </span>
                      <% else %>
                        <span class="muted">—</span>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <%= if Map.get(@payload, :outcomes) do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Outcomes (last 7 days)</h2>
                <p class="section-copy">Issue resolution quality. Zero-touch = merged without human feedback.</p>
              </div>
            </div>

            <div class="metric-grid">
              <div class="metric-card">
                <p class="metric-label">Total closed</p>
                <p class="metric-value"><%= @payload.outcomes.total %></p>
              </div>
              <div class="metric-card">
                <p class="metric-label">Zero-touch rate</p>
                <p class="metric-value"><%= @payload.outcomes.zero_touch_rate %>%%</p>
              </div>
              <div class="metric-card">
                <p class="metric-label">Zero-touch</p>
                <p class="metric-value"><%= @payload.outcomes.zero_touch %></p>
              </div>
              <div class="metric-card">
                <p class="metric-label">One-touch</p>
                <p class="metric-value"><%= @payload.outcomes.one_touch %></p>
              </div>
            </div>
          </section>
        <% end %>
      <% end %>
    </section>
    """
  end

  defp outcome_badge_class(:success), do: "status-badge status-badge-live"
  defp outcome_badge_class("success"), do: "status-badge status-badge-live"
  defp outcome_badge_class(_), do: "status-badge status-badge-offline"

  defp format_duration(nil), do: "n/a"

  defp format_duration(seconds) when is_number(seconds) do
    minutes = div(trunc(seconds), 60)
    secs = rem(trunc(seconds), 60)
    if minutes > 0, do: "#{minutes}m #{secs}s", else: "#{secs}s"
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || Karkhana.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.agent_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now)
       when is_integer(turn_count) and turn_count > 0 do
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

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now)
       when is_binary(started_at) do
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

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) ->
        "#{base} state-badge-active"

      String.contains?(normalized, ["blocked", "error", "failed"]) ->
        "#{base} state-badge-danger"

      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) ->
        "#{base} state-badge-warning"

      true ->
        base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp short_hash(nil), do: "—"
  defp short_hash(hash) when is_binary(hash) and byte_size(hash) > 8, do: binary_part(hash, 0, 8)
  defp short_hash(hash) when is_binary(hash), do: hash
end
