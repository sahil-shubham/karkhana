defmodule KarkhanaWeb.SessionLive do
  @moduledoc """
  Live session detail — real-time event stream for a running session.
  Subscribes to PubSub "session:<identifier>" for per-event updates.
  """

  use Phoenix.LiveView, layout: {KarkhanaWeb.Layouts, :app}

  alias Karkhana.{Session, Store}

  @impl true
  def mount(%{"identifier" => identifier}, _session, socket) do
    session_pid = Session.lookup(identifier)

    {session_info, events, completed_run} =
      if session_pid do
        info =
          try do
            Session.status(session_pid)
          catch
            :exit, _ -> nil
          end

        evts =
          try do
            Session.events(session_pid, 200)
          catch
            :exit, _ -> []
          end

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Karkhana.PubSub, "session:#{identifier}")
        end

        {info, evts, nil}
      else
        # Session not running — show most recent completed run
        run = load_run(identifier)
        {nil, [], run}
      end

    # Load all runs for this issue (for the history section)
    all_runs =
      case Store.list_runs(issue_identifier: identifier, limit: 10) do
        {:ok, runs} -> runs
        _ -> []
      end

    socket =
      socket
      |> assign(:identifier, identifier)
      |> assign(:session, session_info)
      |> assign(:events, events)
      |> assign(:completed_run, completed_run)
      |> assign(:all_runs, all_runs)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) and session_pid, do: schedule_tick()

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info({:session_event, event}, socket) do
    events = socket.assigns.events ++ [event]
    # Cap at 500 in the LiveView (generous for scrolling)
    events = if length(events) > 500, do: Enum.drop(events, length(events) - 500), else: events
    {:noreply, assign(socket, :events, events)}
  end

  def handle_info({:session_completed, summary}, socket) do
    run = load_run(socket.assigns.identifier)

    {:noreply,
     socket
     |> assign(:session, summary)
     |> assign(:completed_run, run)}
  end

  def handle_info({:session_failed, summary}, socket) do
    run = load_run(socket.assigns.identifier)

    {:noreply,
     socket
     |> assign(:session, summary)
     |> assign(:completed_run, run)}
  end

  def handle_info({:session_status, summary}, socket) do
    {:noreply, assign(socket, :session, summary)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card" style="padding: 1rem 1.5rem;">
        <div style="display: flex; justify-content: space-between; align-items: center;">
          <div>
            <a href="/" style="color: inherit; text-decoration: none; opacity: 0.6;">← Dashboard</a>
            <h1 class="hero-title" style="margin-top: 0.25rem; font-size: 1.5rem;">
              <%= @identifier %>
              <%= if @session do %>
                <span class="mode-badge" style="margin-left: 0.5rem; font-size: 0.9rem;"><%= @session.mode || "—" %></span>
                <span class={state_class(@session.status)} style="margin-left: 0.5rem; font-size: 0.9rem;"><%= @session.status %></span>
              <% end %>
            </h1>
          </div>
          <%= if @session && @session.started_at do %>
            <div class="numeric" style="text-align: right;">
              <div><%= format_runtime(@session.started_at, @now) %></div>
              <div class="muted">$<%= format_cost(@session && @session.cost_usd) %></div>
            </div>
          <% end %>
        </div>
      </header>

      <%= if @session do %>
        <section class="metric-grid" style="margin-top: 1rem;">
          <article class="metric-card">
            <p class="metric-label">Tokens</p>
            <p class="metric-value numeric"><%= format_int(@session.tokens.total) %></p>
            <p class="metric-detail numeric muted">In <%= format_int(@session.tokens.input) %> / Out <%= format_int(@session.tokens.output) %></p>
          </article>
          <article class="metric-card">
            <p class="metric-label">Turns</p>
            <p class="metric-value numeric"><%= @session.turn_count %></p>
          </article>
          <article class="metric-card">
            <p class="metric-label">Events</p>
            <p class="metric-value numeric"><%= @session.event_count %></p>
          </article>
          <article class="metric-card">
            <p class="metric-label">Sandbox</p>
            <p class="metric-value" style="font-size: 0.9rem;"><%= short_id(@session.sandbox_id) %></p>
          </article>
        </section>
      <% end %>

      <%= if @completed_run do %>
        <section class="section-card" style="margin-top: 1rem;">
          <div class="section-header">
            <h2 class="section-title">Run result</h2>
          </div>
          <div class="metric-grid">
            <article class="metric-card">
              <p class="metric-label">Outcome</p>
              <p class={outcome_class(@completed_run.outcome)}><%= @completed_run.outcome %></p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Cost</p>
              <p class="metric-value numeric">$<%= format_cost(@completed_run.cost_usd) %></p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Duration</p>
              <p class="metric-value numeric"><%= format_duration(@completed_run.duration_seconds) %></p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Gate</p>
              <p class="metric-value"><%= @completed_run.gate_result || "—" %></p>
            </article>
          </div>
          <%= if @completed_run.error_message do %>
            <div style="margin-top: 1rem; padding: 0.75rem; background: #fef2f2; border-radius: 6px; color: #991b1b; font-size: 0.875rem;">
              <%= @completed_run.error_message %>
            </div>
          <% end %>
        </section>
      <% end %>

      <section class="section-card" style="margin-top: 1rem;">
        <div class="section-header">
          <h2 class="section-title">Event stream</h2>
          <span class="muted"><%= length(@events) %> events</span>
        </div>

        <%= if @events == [] do %>
          <p class="empty-state">No events yet.</p>
        <% else %>
          <div class="event-stream" id="event-stream">
            <div :for={event <- @events} class={"event-row event-#{event.type}"}>
              <span class="event-time"><%= format_time(event.at) %></span>
              <span class={"event-type-badge event-type-#{event.type}"}><%= event_type_label(event.type) %></span>
              <span class="event-summary"><%= event.summary %></span>
            </div>
          </div>
        <% end %>
      </section>

      <%= if @all_runs != [] do %>
        <section class="section-card" style="margin-top: 1rem;">
          <div class="section-header">
            <h2 class="section-title">Run history</h2>
          </div>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 600px;">
              <thead>
                <tr>
                  <th>Mode</th>
                  <th>Outcome</th>
                  <th>Gate</th>
                  <th>Cost</th>
                  <th>Duration</th>
                  <th>Started</th>
                  <th>Error</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={run <- @all_runs}>
                  <td><span class="mode-badge"><%= run.mode || "—" %></span></td>
                  <td><span class={outcome_class(run.outcome)}><%= run.outcome %></span></td>
                  <td>
                    <%= case run.gate_result do %>
                      <% "pass" -> %><span style="color: #22c55e;">✓</span>
                      <% "fail" -> %><span style="color: #ef4444;">✗</span>
                      <% _ -> %><span class="muted">—</span>
                    <% end %>
                  </td>
                  <td class="numeric">$<%= format_cost(run.cost_usd) %></td>
                  <td class="numeric"><%= format_duration(run.duration_seconds) %></td>
                  <td class="muted" style="font-size: 0.8rem;"><%= run.started_at %></td>
                  <td>
                    <%= if run.error_message do %>
                      <span style="font-size: 0.8rem; color: #ef4444;" title={run.error_message}>
                        <%= String.slice(run.error_message, 0, 80) %>
                      </span>
                    <% end %>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      <% end %>
    </section>
    """
  end

  # --- Data ---

  defp load_run(identifier) do
    case Store.list_runs(limit: 1, issue_identifier: identifier) do
      {:ok, [run | _]} -> run
      _ -> nil
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

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: ""

  defp short_id(nil), do: "—"
  defp short_id(id) when byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short_id(id), do: id

  defp event_type_label(:tool_use), do: "tool"
  defp event_type_label(:assistant), do: "assistant"
  defp event_type_label(:session_started), do: "session"
  defp event_type_label(:turn_start), do: "turn"
  defp event_type_label(:turn_end), do: "turn"
  defp event_type_label(:result), do: "result"
  defp event_type_label(:error), do: "error"
  defp event_type_label(type), do: to_string(type)

  defp state_class(:completed), do: "status-badge status-badge-live"
  defp state_class(:failed), do: "status-badge status-badge-offline"
  defp state_class(:running), do: "status-badge status-badge-active"
  defp state_class(:gates), do: "status-badge status-badge-warning"
  defp state_class(_), do: "status-badge"

  defp outcome_class("success"), do: "metric-value status-badge status-badge-live"
  defp outcome_class(:success), do: "metric-value status-badge status-badge-live"
  defp outcome_class(_), do: "metric-value status-badge status-badge-offline"

  defp schedule_tick, do: Process.send_after(self(), :tick, 1_000)
end
