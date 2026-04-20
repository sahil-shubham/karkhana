defmodule KarkhanaWeb.SessionLive do
  @moduledoc """
  Session detail — real-time event stream for running sessions,
  run summary + archived transcript for past sessions.
  """

  use Phoenix.LiveView, layout: {KarkhanaWeb.Layouts, :app}

  import KarkhanaWeb.Formatters

  alias Karkhana.{Session, SessionReader, Store}

  @max_events 500

  @impl true
  def mount(%{"identifier" => identifier}, _session, socket) do
    session_pid = Session.lookup(identifier)

    {session_info, events, completed_run} =
      if session_pid do
        info = safe_call(fn -> Session.status(session_pid) end)
        evts = safe_call(fn -> Session.events(session_pid, 200) end, [])

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Karkhana.PubSub, "session:#{identifier}")
        end

        {info, evts, nil}
      else
        run = load_latest_run(identifier)
        {nil, [], run}
      end

    all_runs =
      case Store.list_runs(issue_identifier: identifier, limit: 20) do
        {:ok, runs} -> runs
        _ -> []
      end

    # Load archived transcript for past sessions
    transcript = if is_nil(session_pid), do: load_transcript(identifier), else: nil

    socket =
      socket
      |> assign(:identifier, identifier)
      |> assign(:session, session_info)
      |> assign(:events, events)
      |> assign(:event_count, length(events))
      |> assign(:completed_run, completed_run)
      |> assign(:all_runs, all_runs)
      |> assign(:transcript, transcript)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) and session_pid, do: schedule_tick()

    {:ok, socket}
  end

  # --- PubSub handlers ---

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info({:session_event, event}, socket) do
    count = socket.assigns.event_count + 1

    events =
      if count > @max_events do
        Enum.drop(socket.assigns.events, 1) ++ [event]
      else
        socket.assigns.events ++ [event]
      end

    {:noreply,
     socket
     |> assign(:events, events)
     |> assign(:event_count, min(count, @max_events))}
  end

  def handle_info({:session_completed, summary}, socket) do
    run = load_latest_run(socket.assigns.identifier)
    transcript = load_transcript(socket.assigns.identifier)

    all_runs =
      case Store.list_runs(issue_identifier: socket.assigns.identifier, limit: 20) do
        {:ok, runs} -> runs
        _ -> socket.assigns.all_runs
      end

    {:noreply,
     socket
     |> assign(:session, summary)
     |> assign(:completed_run, run)
     |> assign(:transcript, transcript)
     |> assign(:all_runs, all_runs)}
  end

  def handle_info({:session_failed, summary}, socket) do
    run = load_latest_run(socket.assigns.identifier)

    all_runs =
      case Store.list_runs(issue_identifier: socket.assigns.identifier, limit: 20) do
        {:ok, runs} -> runs
        _ -> socket.assigns.all_runs
      end

    {:noreply,
     socket
     |> assign(:session, summary)
     |> assign(:completed_run, run)
     |> assign(:all_runs, all_runs)}
  end

  def handle_info({:session_status, summary}, socket) do
    {:noreply, assign(socket, :session, summary)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dash">
      <header class="dash-header">
        <a href="/" class="back">← Dashboard</a>
        <div class="session-title">
          <h1><%= @identifier %></h1>
          <%= if @session do %>
            <span class={status_class(@session.status)}><%= @session.status %></span>
            <span class="mode"><%= @session.mode || "—" %></span>
          <% end %>
        </div>
      </header>

      <%= if @session do %>
        <.live_metrics session={@session} now={@now} />
      <% end %>

      <%= if @completed_run do %>
        <.run_result run={@completed_run} />
      <% end %>

      <%= if @events != [] do %>
        <.event_stream events={@events} />
      <% end %>

      <%= if @transcript && @events == [] do %>
        <.transcript_section transcript={@transcript} />
      <% end %>

      <%= if @all_runs != [] do %>
        <.run_history runs={@all_runs} />
      <% end %>
    </div>
    """
  end

  # --- Components ---

  defp live_metrics(assigns) do
    ~H"""
    <div class="stat-row">
      <div class="stat"><span class="stat-n"><%= format_int(@session.tokens.total) %></span> tokens</div>
      <div class="stat"><span class="stat-n mono">$<%= format_cost(@session.cost_usd) %></span> cost</div>
      <div class="stat"><span class="stat-n"><%= @session.turn_count %></span> turns</div>
      <div class="stat"><span class="stat-n"><%= format_runtime(@session.started_at, @now) %></span> elapsed</div>
      <div class="stat"><span class="stat-n dim"><%= short_id(@session.sandbox_id) %></span> sandbox</div>
    </div>
    """
  end

  defp run_result(assigns) do
    ~H"""
    <section class="card">
      <h2>Result</h2>
      <div class="stat-row">
        <div class="stat"><span class={outcome_class(@run.outcome)}><%= @run.outcome %></span></div>
        <div class="stat"><span class="stat-n mono">$<%= format_cost(@run.cost_usd) %></span> cost</div>
        <div class="stat"><span class="stat-n"><%= format_duration(@run.duration_seconds) %></span> duration</div>
        <div class="stat"><span class="stat-n"><%= @run.gate_result || "—" %></span> gate</div>
      </div>
      <%= if @run.error_message do %>
        <div class="err-block"><%= @run.error_message %></div>
      <% end %>
    </section>
    """
  end

  defp event_stream(assigns) do
    ~H"""
    <section class="card">
      <div class="card-head">
        <h2>Events</h2>
        <span class="dim"><%= length(@events) %></span>
      </div>
      <div class="events" id="event-stream" phx-hook="AutoScroll">
        <div :for={event <- @events} class={"ev ev-#{event.type}"}>
          <span class="ev-time mono"><%= format_time(event.at) %></span>
          <span class={"ev-type ev-type-#{event.type}"}><%= event_label(event.type) %></span>
          <span class="ev-body"><%= event.summary %></span>
        </div>
      </div>
    </section>
    """
  end

  defp transcript_section(assigns) do
    ~H"""
    <section class="card">
      <div class="card-head">
        <h2>Transcript</h2>
        <span class="dim"><%= length(@transcript.turns) %> turns</span>
      </div>
      <div class="events" id="transcript-stream">
        <div :for={turn <- @transcript.turns} class={"ev ev-#{String.downcase(turn.role)}"}>
          <span class={"ev-type ev-type-#{String.downcase(turn.role)}"}><%= turn.role %></span>
          <span class="ev-body">
            <%= if turn.tools != [] do %>
              <div :for={tool <- turn.tools} class="ev-tool">🔧 <%= tool %></div>
            <% end %>
            <div class="ev-text"><%= turn.text %></div>
          </span>
        </div>
      </div>
    </section>
    """
  end

  defp run_history(assigns) do
    ~H"""
    <section class="card">
      <h2>Run history</h2>
      <table class="tbl">
        <thead>
          <tr>
            <th>Mode</th>
            <th>Outcome</th>
            <th>Gate</th>
            <th class="r">Cost</th>
            <th class="r">Duration</th>
            <th>Started</th>
            <th>Error</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={run <- @runs}>
            <td><span class="mode"><%= run.mode || "—" %></span></td>
            <td><span class={outcome_class(run.outcome)}><%= run.outcome %></span></td>
            <td><%= gate_icon(run.gate_result) %></td>
            <td class="r mono">$<%= format_cost(run.cost_usd) %></td>
            <td class="r mono"><%= format_duration(run.duration_seconds) %></td>
            <td class="dim"><%= format_started(run.started_at) %></td>
            <td>
              <%= if run.error_message do %>
                <span class="err" title={run.error_message}><%= String.slice(run.error_message, 0, 80) %></span>
              <% end %>
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  # --- Data ---

  defp load_latest_run(identifier) do
    case Store.list_runs(limit: 1, issue_identifier: identifier) do
      {:ok, [run | _]} -> run
      _ -> nil
    end
  end

  defp load_transcript(identifier) do
    # Try to find archived sessions by sandbox name pattern
    sandbox_name = "karkhana-#{identifier}"

    case SessionReader.list_sessions(sandbox_name) do
      [latest | _] ->
        case SessionReader.read_session(sandbox_name, latest) do
          {:ok, summary} -> summary
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp safe_call(fun, default \\ nil) do
    try do
      fun.()
    catch
      :exit, _ -> default
    end
  end

  # --- Helpers ---

  defp event_label(:tool_use), do: "tool"
  defp event_label(:assistant), do: "llm"
  defp event_label(:session_started), do: "start"
  defp event_label(:turn_start), do: "turn"
  defp event_label(:turn_end), do: "turn"
  defp event_label(:result), do: "done"
  defp event_label(:error), do: "error"
  defp event_label(type), do: to_string(type)

  defp status_class(:running), do: "tag tag-active"
  defp status_class(:gates), do: "tag tag-warn"
  defp status_class(:completed), do: "tag tag-ok"
  defp status_class(:failed), do: "tag tag-err"
  defp status_class(_), do: "tag"

  defp outcome_class(outcome) do
    case to_string(outcome) do
      "success" -> "tag tag-ok"
      "gate_failed" -> "tag tag-warn"
      _ -> "tag tag-err"
    end
  end

  defp gate_icon("pass"), do: {:safe, ~s(<span class="gate-pass">✓</span>)}
  defp gate_icon("fail"), do: {:safe, ~s(<span class="gate-fail">✗</span>)}
  defp gate_icon(_), do: {:safe, ~s(<span class="dim">—</span>)}

  defp format_started(nil), do: "—"

  defp format_started(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%b %d %H:%M")
      _ -> dt
    end
  end

  defp format_started(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d %H:%M")

  defp schedule_tick, do: Process.send_after(self(), :tick, 1_000)
end
