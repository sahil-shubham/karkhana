defmodule KarkhanaWeb.DashboardLive do
  @moduledoc """
  Main dashboard — active sessions, summary metrics, recent runs.
  """

  use Phoenix.LiveView, layout: {KarkhanaWeb.Layouts, :app}

  import KarkhanaWeb.Formatters

  alias Karkhana.{Session, Store}

  @sessions_topic "sessions"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Karkhana.PubSub, @sessions_topic)
      schedule_tick()
    end

    socket =
      socket
      |> assign(:sessions, load_sessions())
      |> assign(:recent_runs, load_recent_runs())
      |> assign(:stats, load_stats())
      |> assign(:now, DateTime.utc_now())

    {:ok, socket}
  end

  # --- PubSub handlers ---

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info({:session_started, summary}, socket) do
    sessions = Map.put(socket.assigns.sessions, summary.identifier, summary)
    {:noreply, assign(socket, :sessions, sessions)}
  end

  def handle_info({:session_completed, summary}, socket) do
    sessions = Map.delete(socket.assigns.sessions, summary.identifier)

    {:noreply,
     socket
     |> assign(:sessions, sessions)
     |> assign(:recent_runs, load_recent_runs())
     |> assign(:stats, load_stats())}
  end

  def handle_info({:session_failed, summary}, socket) do
    sessions = Map.delete(socket.assigns.sessions, summary.identifier)

    {:noreply,
     socket
     |> assign(:sessions, sessions)
     |> assign(:recent_runs, load_recent_runs())
     |> assign(:stats, load_stats())}
  end

  def handle_info({:session_status, summary}, socket) do
    sessions = Map.put(socket.assigns.sessions, summary.identifier, summary)
    {:noreply, assign(socket, :sessions, sessions)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dash">
      <header class="dash-header">
        <h1>Karkhana</h1>
        <span class="live-dot"></span>
      </header>

      <div class="stat-row">
        <div class="stat"><span class="stat-n"><%= map_size(@sessions) %></span> running</div>
        <div class="stat"><span class="stat-n"><%= @stats.total_runs %></span> total runs</div>
        <div class="stat"><span class="stat-n">$<%= format_cost(@stats.total_cost) %></span> spent</div>
        <div class="stat"><span class="stat-n"><%= format_pct(@stats.gate_pass_rate) %></span> gate pass</div>
      </div>

      <%= if @sessions != %{} do %>
        <section class="card">
          <h2>Running</h2>
          <table class="tbl">
            <thead>
              <tr>
                <th>Issue</th>
                <th>State</th>
                <th>Mode</th>
                <th>Status</th>
                <th class="r">Tokens</th>
                <th class="r">Cost</th>
                <th class="r">Time</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{_id, s} <- Enum.sort_by(@sessions, fn {_, s} -> s.identifier end)}>
                <td>
                  <a href={"/sessions/#{s.identifier}"} class="issue-link"><%= s.identifier %></a>
                  <%= if s.attempt && s.attempt > 0 do %>
                    <span class="dim">×<%= s.attempt + 1 %></span>
                  <% end %>
                </td>
                <td><span class={state_class(s.state)}><%= s.state %></span></td>
                <td><span class="mode"><%= s.mode || "—" %></span></td>
                <td><span class={status_class(s.status)}><%= s.status %></span></td>
                <td class="r mono"><%= format_int(s.tokens.total) %></td>
                <td class="r mono">$<%= format_cost(s.cost_usd) %></td>
                <td class="r mono"><%= format_runtime(s.started_at, @now) %></td>
              </tr>
            </tbody>
          </table>
        </section>
      <% end %>

      <section class="card">
        <h2>Recent runs</h2>
        <%= if @recent_runs == [] do %>
          <p class="empty">No completed runs yet.</p>
        <% else %>
          <table class="tbl">
            <thead>
              <tr>
                <th>Issue</th>
                <th>Mode</th>
                <th>Outcome</th>
                <th>Gate</th>
                <th class="r">Tokens</th>
                <th class="r">Cost</th>
                <th class="r">Duration</th>
                <th>Error</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={run <- @recent_runs}>
                <td><a href={"/sessions/#{run.issue_identifier}"} class="issue-link"><%= run.issue_identifier %></a></td>
                <td><span class="mode"><%= run.mode || "—" %></span></td>
                <td><span class={outcome_class(run.outcome)}><%= run.outcome %></span></td>
                <td><%= gate_icon(run.gate_result) %></td>
                <td class="r mono"><%= format_int(run.tokens_total || 0) %></td>
                <td class="r mono">$<%= format_cost(run.cost_usd) %></td>
                <td class="r mono"><%= format_duration(run.duration_seconds) %></td>
                <td>
                  <%= if run.error_message do %>
                    <span class="err" title={run.error_message}><%= String.slice(run.error_message, 0, 80) %></span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        <% end %>
      </section>
    </div>
    """
  end

  # --- Data ---

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
    case Store.list_runs(limit: 25) do
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

  # --- Helpers ---

  defp format_pct(rates) when is_map(rates) and map_size(rates) > 0 do
    avg = rates |> Map.values() |> Enum.sum() |> then(&(&1 / map_size(rates)))
    "#{round(avg * 100)}%"
  end

  defp format_pct(_), do: "—"

  defp gate_icon("pass"), do: {:safe, ~s(<span class="gate-pass">✓</span>)}
  defp gate_icon("fail"), do: {:safe, ~s(<span class="gate-fail">✗</span>)}
  defp gate_icon(_), do: {:safe, ~s(<span class="dim">—</span>)}

  defp state_class(state) do
    n = (state || "") |> to_string() |> String.downcase()

    cond do
      n in ["planning", "implementing", "debugging", "qa", "in progress", "todo"] -> "tag tag-active"
      n in ["plan review", "in review"] -> "tag tag-warn"
      n in ["done"] -> "tag tag-ok"
      n in ["cancelled", "canceled"] -> "tag tag-off"
      true -> "tag"
    end
  end

  defp status_class(status) do
    case status do
      :running -> "tag tag-active"
      :gates -> "tag tag-warn"
      :completed -> "tag tag-ok"
      :failed -> "tag tag-err"
      :starting -> "tag"
      _ -> "tag"
    end
  end

  defp outcome_class(outcome) do
    case to_string(outcome) do
      "success" -> "tag tag-ok"
      "gate_failed" -> "tag tag-warn"
      _ -> "tag tag-err"
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, 2_000)
end
