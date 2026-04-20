defmodule KarkhanaWeb.DashboardLive do
  @moduledoc """
  Main dashboard — active sessions, summary metrics, recent runs.
  Subscribes to PubSub "sessions" topic for real-time updates.
  """

  use Phoenix.LiveView, layout: {KarkhanaWeb.Layouts, :app}

  alias Karkhana.{Session, Store}

  @sessions_topic "sessions"
  @tick_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Karkhana.PubSub, @sessions_topic)
      schedule_tick()
    end

    sessions = load_sessions()
    recent_runs = load_recent_runs()
    stats = load_stats()

    socket =
      socket
      |> assign(:sessions, sessions)
      |> assign(:recent_runs, recent_runs)
      |> assign(:stats, stats)
      |> assign(:now, DateTime.utc_now())

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()

    {:noreply,
     socket
     |> assign(:sessions, load_sessions())
     |> assign(:now, DateTime.utc_now())}
  end

  def handle_info({:session_started, summary}, socket) do
    sessions = Map.put(socket.assigns.sessions, summary.identifier, summary)
    {:noreply, assign(socket, :sessions, sessions)}
  end

  def handle_info({:session_completed, summary}, socket) do
    sessions = Map.delete(socket.assigns.sessions, summary.identifier)
    recent_runs = load_recent_runs()

    {:noreply,
     socket
     |> assign(:sessions, sessions)
     |> assign(:recent_runs, recent_runs)
     |> assign(:stats, load_stats())}
  end

  def handle_info({:session_failed, summary}, socket) do
    sessions = Map.delete(socket.assigns.sessions, summary.identifier)
    recent_runs = load_recent_runs()

    {:noreply,
     socket
     |> assign(:sessions, sessions)
     |> assign(:recent_runs, recent_runs)
     |> assign(:stats, load_stats())}
  end

  def handle_info({:session_status, summary}, socket) do
    sessions = Map.put(socket.assigns.sessions, summary.identifier, summary)
    {:noreply, assign(socket, :sessions, sessions)}
  end

  def handle_info({:session_event, _event}, socket) do
    # Individual events handled on the detail page, not here
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Karkhana</p>
            <h1 class="hero-title">Dashboard</h1>
          </div>
          <span class="status-badge status-badge-live">
            <span class="status-badge-dot"></span> Live
          </span>
        </div>
      </header>

      <section class="metric-grid">
        <article class="metric-card">
          <p class="metric-label">Running</p>
          <p class="metric-value numeric"><%= map_size(@sessions) %></p>
        </article>
        <article class="metric-card">
          <p class="metric-label">Total runs</p>
          <p class="metric-value numeric"><%= @stats.total_runs %></p>
        </article>
        <article class="metric-card">
          <p class="metric-label">Total cost</p>
          <p class="metric-value numeric">$<%= format_cost(@stats.total_cost) %></p>
        </article>
        <article class="metric-card">
          <p class="metric-label">Gate pass rate</p>
          <p class="metric-value numeric"><%= format_pct(@stats.gate_pass_rate) %></p>
        </article>
      </section>

      <section class="section-card">
        <div class="section-header">
          <h2 class="section-title">Running sessions</h2>
        </div>

        <%= if @sessions == %{} do %>
          <p class="empty-state">No active sessions.</p>
        <% else %>
          <div :for={{_id, s} <- Enum.sort_by(@sessions, fn {_, s} -> s.identifier end)} class="session-card">
            <div class="session-card-header">
              <div>
                <a href={"/s/#{s.identifier}"} target="_blank" class="issue-id" style="font-size: 1.1rem; text-decoration: none;">
                  <%= s.identifier %>
                </a>
                <span class={state_badge_class(s.state)} style="margin-left: 0.5rem;"><%= s.state %></span>
                <%= if s.mode do %>
                  <span class="mode-badge" style="margin-left: 0.25rem;"><%= s.mode %></span>
                <% end %>
                <%= if s.attempt && s.attempt > 0 do %>
                  <span class="muted" style="margin-left: 0.5rem;">attempt <%= s.attempt + 1 %></span>
                <% end %>
              </div>
              <div class="numeric">
                <span><%= format_runtime(s.started_at, @now) %></span>
                <%= if s.cost_usd && s.cost_usd > 0 do %>
                  <span class="muted" style="margin-left: 0.75rem;">$<%= format_cost(s.cost_usd) %></span>
                <% end %>
              </div>
            </div>

            <div class="session-card-status" style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap;">
              <span>
                <span style="opacity: 0.6;"><%= s.status %></span>
                <span class="muted" style="margin-left: 0.75rem;">Tokens: <span class="numeric"><%= format_int(s.tokens.total) %></span></span>
                <span class="muted" style="margin-left: 0.5rem;">Turns: <span class="numeric"><%= s.turn_count %></span></span>
              </span>
              <a href={"/s/#{s.identifier}"} target="_blank" style="font-size: 0.85rem;">View live →</a>
            </div>
          </div>
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-header">
          <h2 class="section-title">Recent runs</h2>
        </div>

        <%= if @recent_runs == [] do %>
          <p class="empty-state">No completed runs yet.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 700px;">
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
                <tr :for={run <- @recent_runs}>
                  <td>
                    <a href={"/s/#{run.issue_identifier}"} target="_blank" class="issue-id" style="text-decoration: none;">
                      <%= run.issue_identifier %>
                    </a>
                  </td>
                  <td><span class="mode-badge"><%= run.mode || "—" %></span></td>
                  <td>
                    <span class={outcome_class(run.outcome)}>
                      <%= run.outcome %>
                    </span>
                  </td>
                  <td>
                    <%= case run.gate_result do %>
                      <% "pass" -> %><span style="color: #22c55e;">✓</span>
                      <% "fail" -> %><span style="color: #ef4444;">✗</span>
                      <% _ -> %><span class="muted">—</span>
                    <% end %>
                  </td>
                  <td class="numeric">$<%= format_cost(run.cost_usd) %></td>
                  <td class="numeric"><%= format_duration(run.duration_seconds) %></td>
                  <td>
                    <%= if run.error_message do %>
                      <span style="font-size: 0.8rem; color: #ef4444;" title={run.error_message}>
                        <%= String.slice(run.error_message || "", 0, 100) %>
                      </span>
                    <% end %>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  # --- Data loading ---

  defp load_sessions do
    Session.list_running()
    |> Enum.reduce(%{}, fn identifier, acc ->
      case Session.lookup(identifier) do
        nil ->
          acc

        pid ->
          try do
            Map.put(acc, identifier, Session.status(pid))
          catch
            :exit, _ -> acc
          end
      end
    end)
  rescue
    _ -> %{}
  end

  defp load_recent_runs do
    case Store.list_runs(limit: 20) do
      {:ok, runs} -> runs
      _ -> []
    end
  end

  defp load_stats do
    case Store.run_stats() do
      {:ok, stats} ->
        %{
          total_runs: stats[:total] || 0,
          total_cost: stats[:total_cost] || 0.0,
          gate_pass_rate: get_in(stats, [:gate_pass_rate]) || %{}
        }

      _ ->
        %{total_runs: 0, total_cost: 0.0, gate_pass_rate: %{}}
    end
  end

  # --- Formatters ---

  defp format_runtime(%DateTime{} = started, %DateTime{} = now) do
    secs = max(DateTime.diff(now, started, :second), 0)
    m = div(secs, 60)
    s = rem(secs, 60)
    "#{m}m #{s}s"
  end

  defp format_runtime(started, now) when is_binary(started) do
    case DateTime.from_iso8601(started) do
      {:ok, dt, _} -> format_runtime(dt, now)
      _ -> "—"
    end
  end

  defp format_runtime(_, _), do: "—"

  defp format_cost(nil), do: "0.00"
  defp format_cost(cost) when is_float(cost), do: :erlang.float_to_binary(cost, decimals: 2)
  defp format_cost(_), do: "0.00"

  defp format_pct(rates) when is_map(rates) and map_size(rates) > 0 do
    avg = rates |> Map.values() |> Enum.sum() |> then(&(&1 / map_size(rates)))
    "#{round(avg * 100)}%"
  end

  defp format_pct(_), do: "—"

  defp format_int(n) when is_integer(n) do
    n |> Integer.to_string() |> String.reverse() |> String.replace(~r/.{3}(?=.)/, "\\0,") |> String.reverse()
  end

  defp format_int(_), do: "0"

  defp format_duration(nil), do: "—"

  defp format_duration(secs) when is_number(secs) do
    m = div(trunc(secs), 60)
    s = rem(trunc(secs), 60)
    if m > 0, do: "#{m}m #{s}s", else: "#{s}s"
  end

  defp state_badge_class(state) do
    base = "state-badge"
    n = (state || "") |> to_string() |> String.downcase()

    cond do
      n in ["planning", "implementing", "debugging", "qa"] -> "#{base} state-badge-active"
      n in ["plan review", "in review"] -> "#{base} state-badge-warning"
      n in ["done"] -> "#{base} state-badge-live"
      true -> base
    end
  end

  defp outcome_class(outcome) do
    case to_string(outcome) do
      "success" -> "status-badge status-badge-live"
      _ -> "status-badge status-badge-offline"
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
