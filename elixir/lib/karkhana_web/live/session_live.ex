defmodule KarkhanaWeb.SessionLive do
  @moduledoc """
  Unified session detail view.

  - Running session: live PubSub event stream (full fidelity)
  - Session ends while watching: events stay, transcript loads when available
  - Opened after session ended: transcript from archive, or live-read from sandbox
  """

  use Phoenix.LiveView, layout: {KarkhanaWeb.Layouts, :app}

  alias Karkhana.{Session, SessionReader, Store}

  @impl true
  def mount(%{"identifier" => identifier}, _session, socket) do
    session_pid = Session.lookup(identifier)

    {session_info, events, mode} =
      if session_pid do
        info = safe_call(fn -> Session.status(session_pid) end)
        evts = safe_call(fn -> Session.events(session_pid) end, [])

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Karkhana.PubSub, "session:#{identifier}")
        end

        {info, evts, :live}
      else
        # Not running — try to load transcript
        case load_transcript(identifier) do
          {:ok, transcript} ->
            {nil, transcript.turns, :transcript}

          :not_found ->
            # Try live-read from sandbox if it still exists
            case load_transcript_from_sandbox(identifier) do
              {:ok, transcript} ->
                {nil, transcript.turns, :transcript}

              :not_found ->
                {nil, [], :ended}
            end
        end
      end

    # Load latest run for metadata (cost, duration, outcome)
    completed_run = load_latest_run(identifier)

    socket =
      socket
      |> assign(:identifier, identifier)
      |> assign(:session, session_info)
      |> assign(:events, events)
      |> assign(:completed_run, completed_run)
      |> assign(:mode, mode)
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
    {:noreply, assign(socket, :events, socket.assigns.events ++ [event])}
  end

  def handle_info({:session_completed, summary}, socket) do
    run = load_latest_run(socket.assigns.identifier)

    # Try to load transcript — sandbox may still be alive
    {events, mode} =
      case load_transcript_from_sandbox(socket.assigns.identifier) do
        {:ok, transcript} ->
          {transcript.turns, :transcript}

        :not_found ->
          # Keep the live events we already have
          {socket.assigns.events, :ended}
      end

    {:noreply,
     socket
     |> assign(:session, summary)
     |> assign(:completed_run, run)
     |> assign(:events, events)
     |> assign(:mode, mode)}
  end

  def handle_info({:session_failed, summary}, socket) do
    run = load_latest_run(socket.assigns.identifier)

    {:noreply,
     socket
     |> assign(:session, summary)
     |> assign(:completed_run, run)
     |> assign(:mode, :ended)}
  end

  def handle_info({:session_status, summary}, socket) do
    {:noreply, assign(socket, :session, summary)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card" style="padding: 1rem 1.5rem;">
        <div style="display: flex; justify-content: space-between; align-items: center;">
          <div>
            <h1 class="hero-title" style="margin: 0; font-size: 1.5rem;">
              <%= @identifier %>
              <%= if @session do %>
                <span class={state_badge_class(@session.state)} style="margin-left: 0.5rem; font-size: 0.9rem;"><%= @session.state %></span>
                <span class="muted" style="margin-left: 0.25rem; font-size: 0.9rem;"><%= @session.mode || "" %></span>
              <% end %>
              <%= if @mode == :live do %>
                <span class="status-badge status-badge-live" style="margin-left: 0.5rem; font-size: 0.8rem;">
                  <span class="status-badge-dot"></span> Live
                </span>
              <% end %>
            </h1>
          </div>
          <%= if @session && @session.started_at do %>
            <div class="numeric" style="text-align: right;">
              <div><%= format_runtime(@session.started_at, @now) %></div>
              <div class="muted">$<%= format_cost(@session && @session.cost_usd) %></div>
            </div>
          <% else %>
            <%= if @completed_run do %>
              <div class="numeric" style="text-align: right;">
                <div><%= format_duration(@completed_run.duration_seconds) %></div>
                <div class="muted">$<%= format_cost(@completed_run.cost_usd) %></div>
              </div>
            <% end %>
          <% end %>
        </div>
      </header>

      <%= if @session && @mode == :live do %>
        <section class="metric-grid" style="margin-top: 1rem;">
          <article class="metric-card">
            <p class="metric-label">Tokens</p>
            <p class="metric-value numeric"><%= format_int(@session.tokens.total) %></p>
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
            <p class="metric-label">Cost</p>
            <p class="metric-value numeric">$<%= format_cost(@session.cost_usd) %></p>
          </article>
        </section>
      <% end %>

      <%= if @completed_run && @mode != :live do %>
        <section class="metric-grid" style="margin-top: 1rem;">
          <article class="metric-card">
            <p class="metric-label">Outcome</p>
            <p class={outcome_class(@completed_run.outcome)} style="margin-top: 0.35rem;"><%= @completed_run.outcome %></p>
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
        </section>
        <%= if @completed_run.error_message do %>
          <div style="margin-top: 0.75rem; padding: 0.75rem; background: #fef2f2; border-radius: 6px; color: #991b1b; font-size: 0.875rem;">
            <%= @completed_run.error_message %>
          </div>
        <% end %>
      <% end %>

      <section class="section-card" style="margin-top: 1rem;">
        <div class="section-header">
          <h2 class="section-title">
            <%= case @mode do %>
              <% :live -> %>Event stream
              <% :transcript -> %>Transcript
              <% :ended -> %>Session
            <% end %>
          </h2>
          <span class="muted"><%= length(@events) %> <%= if @mode == :transcript, do: "turns", else: "events" %></span>
        </div>

        <%= if @events == [] do %>
          <p class="empty-state">
            <%= if @mode == :ended do %>
              No transcript available. Session data was not archived.
            <% else %>
              Waiting for events…
            <% end %>
          </p>
        <% else %>
          <div class="event-stream" id="event-stream" phx-hook="AutoScroll">
            <%= case @mode do %>
              <% :live -> %>
                <%= for event <- @events do %>
                  <.render_event event={event} />
                <% end %>
              <% :transcript -> %>
                <%= for turn <- @events do %>
                  <.render_turn turn={turn} />
                <% end %>
              <% :ended -> %>
                <%= for event <- @events do %>
                  <.render_event event={event} />
                <% end %>
            <% end %>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  # --- Live event rendering (from PubSub, full fidelity via event.raw) ---

  defp render_event(%{event: %{type: :tool_use, raw: raw}} = assigns) do
    tool = Map.get(raw, "toolName") || Map.get(raw, "tool") || "tool"
    args = Map.get(raw, "args") || %{}
    result = Map.get(raw, "result")
    is_error = Map.get(raw, "isError", false)
    subtype = Map.get(raw, "type", "")

    detail =
      cond do
        args["command"] -> args["command"]
        args["path"] -> args["path"]
        true -> nil
      end

    assigns =
      assigns
      |> assign(:tool, tool)
      |> assign(:detail, detail)
      |> assign(:result, result)
      |> assign(:is_error, is_error)
      |> assign(:subtype, subtype)

    ~H"""
    <div class={"event-row event-tool_use #{if @is_error, do: "event-error"}"}>
      <span class="event-time"><%= format_time(@event.at) %></span>
      <span class="event-type-badge event-type-tool_use"><%= @tool %></span>
      <div class="event-detail">
        <%= if @detail do %>
          <pre class="event-pre"><%= @detail %></pre>
        <% end %>
        <%= if @result && @subtype == "tool_execution_end" do %>
          <pre class={"event-pre event-result #{if @is_error, do: "event-result-error"}"}><%= format_result(@result) %></pre>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_event(%{event: %{type: :assistant, raw: raw}} = assigns) do
    content =
      Map.get(raw, "content") ||
        get_in(raw, ["message", "content"]) || []

    blocks =
      case content do
        blocks when is_list(blocks) -> blocks
        _ -> []
      end

    assigns = assign(assigns, :blocks, blocks)

    ~H"""
    <div class="event-row event-assistant">
      <span class="event-time"><%= format_time(@event.at) %></span>
      <span class="event-type-badge event-type-assistant">assistant</span>
      <div class="event-detail">
        <%= for block <- @blocks do %>
          <%= case Map.get(block, "type") do %>
            <% "thinking" -> %>
              <div class="event-thinking">
                <pre class="event-pre"><%= Map.get(block, "thinking", "") %></pre>
              </div>
            <% "text" -> %>
              <pre class="event-pre"><%= Map.get(block, "text", "") %></pre>
            <% _ -> %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_event(%{event: %{type: type}} = assigns) when type in [:turn_start, :turn_end] do
    ~H"""
    <div class="event-row event-turn">
      <span class="event-time"><%= format_time(@event.at) %></span>
      <span class="event-type-badge event-type-turn"><%= event_type_label(@event.type) %></span>
      <span class="event-summary"><%= @event.summary %></span>
    </div>
    """
  end

  defp render_event(%{event: %{type: :error, raw: raw}} = assigns) do
    message = Map.get(raw, "message") || Map.get(raw, "error") || "Unknown error"
    assigns = assign(assigns, :message, message)

    ~H"""
    <div class="event-row event-error">
      <span class="event-time"><%= format_time(@event.at) %></span>
      <span class="event-type-badge event-type-error">error</span>
      <pre class="event-pre event-result-error"><%= @message %></pre>
    </div>
    """
  end

  defp render_event(assigns) do
    ~H"""
    <div class="event-row">
      <span class="event-time"><%= format_time(@event.at) %></span>
      <span class={"event-type-badge event-type-#{@event.type}"}><%= event_type_label(@event.type) %></span>
      <span class="event-summary"><%= @event.summary %></span>
    </div>
    """
  end

  # --- Transcript rendering (from JSONL archive) ---

  defp render_turn(%{turn: %{role: role} = turn} = assigns) do
    assigns =
      assigns
      |> assign(:role, role)
      |> assign(:tools, turn.tools || [])
      |> assign(:text, turn.text || "")

    ~H"""
    <div class={"event-row event-#{String.downcase(@role)}"}>
      <span class={"event-type-badge event-type-#{String.downcase(@role)}"}><%= @role %></span>
      <div class="event-detail">
        <%= if @tools != [] do %>
          <%= for tool <- @tools do %>
            <pre class="event-pre" style="opacity: 0.7; margin-bottom: 0.25rem;">🔧 <%= tool %></pre>
          <% end %>
        <% end %>
        <pre class="event-pre"><%= @text %></pre>
      </div>
    </div>
    """
  end

  # --- Data loading ---

  defp load_latest_run(identifier) do
    case Store.list_runs(limit: 1, issue_identifier: identifier) do
      {:ok, [run | _]} -> run
      _ -> nil
    end
  end

  defp load_transcript(identifier) do
    sandbox_name = "karkhana-#{identifier}"

    case SessionReader.list_sessions(sandbox_name) do
      [latest | _] ->
        case SessionReader.read_session(sandbox_name, latest) do
          {:ok, summary} -> {:ok, summary}
          _ -> :not_found
        end

      _ ->
        :not_found
    end
  end

  defp load_transcript_from_sandbox(identifier) do
    # Look up sandbox_id from the most recent run
    case load_latest_run(identifier) do
      %{sandbox_id: sandbox_id} when is_binary(sandbox_id) ->
        # Try to list session files in the sandbox
        case Karkhana.Bhatti.Client.exec(
               sandbox_id,
               ["bash", "-c", "ls /home/lohar/karkhana-sessions/*.jsonl 2>/dev/null | tail -1"],
               timeout_sec: 5
             ) do
          {:ok, %{"exit_code" => 0, "stdout" => path}} when byte_size(path) > 0 ->
            path = String.trim(path)

            case SessionReader.read_live_session(sandbox_id, path) do
              {:ok, summary} -> {:ok, summary}
              _ -> :not_found
            end

          _ ->
            :not_found
        end

      _ ->
        :not_found
    end
  rescue
    _ -> :not_found
  end

  defp safe_call(fun, default \\ nil) do
    try do
      fun.()
    catch
      :exit, _ -> default
    end
  end

  # --- Helpers ---

  defp format_result(result) when is_binary(result), do: result
  defp format_result(result) when is_map(result) or is_list(result), do: Jason.encode!(result, pretty: true)
  defp format_result(result), do: inspect(result)

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

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: ""

  defp event_type_label(:tool_use), do: "tool"
  defp event_type_label(:assistant), do: "assistant"
  defp event_type_label(:session_started), do: "session"
  defp event_type_label(:turn_start), do: "turn"
  defp event_type_label(:turn_end), do: "turn"
  defp event_type_label(:result), do: "result"
  defp event_type_label(:error), do: "error"
  defp event_type_label(type), do: to_string(type)

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
      "success" -> "metric-value status-badge status-badge-live"
      _ -> "metric-value status-badge status-badge-offline"
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, 1_000)
end
