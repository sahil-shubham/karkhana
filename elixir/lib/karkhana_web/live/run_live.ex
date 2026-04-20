defmodule KarkhanaWeb.RunLive do
  @moduledoc """
  Past run detail — loads a specific run by ID and its transcript.
  Tries archive first, then live-read from sandbox if still alive.
  """

  use Phoenix.LiveView, layout: {KarkhanaWeb.Layouts, :app}

  alias Karkhana.{SessionReader, Store}

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    {run, transcript} =
      case Store.get_run(run_id) do
        {:ok, run} ->
          transcript = load_transcript(run)
          {run, transcript}

        {:error, :not_found} ->
          {nil, nil}

        {:error, _} ->
          {nil, nil}
      end

    socket =
      socket
      |> assign(:run_id, run_id)
      |> assign(:run, run)
      |> assign(:transcript, transcript)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <%= if @run do %>
        <header class="hero-card" style="padding: 1rem 1.5rem;">
          <div style="display: flex; justify-content: space-between; align-items: center;">
            <div>
              <h1 class="hero-title" style="margin: 0; font-size: 1.5rem;">
                <%= @run.issue_identifier %>
                <span class="muted" style="font-size: 0.9rem; margin-left: 0.5rem;"><%= @run.mode || "" %></span>
                <span class={outcome_class(@run.outcome)} style="margin-left: 0.5rem; font-size: 0.85rem;"><%= @run.outcome %></span>
              </h1>
            </div>
            <div class="numeric" style="text-align: right;">
              <div><%= format_duration(@run.duration_seconds) %></div>
              <div class="muted">$<%= format_cost(@run.cost_usd) %></div>
            </div>
          </div>
        </header>

        <%= if @run.error_message do %>
          <div style="margin-top: 0.75rem; padding: 0.75rem; background: #fef2f2; border-radius: 6px; color: #991b1b; font-size: 0.875rem;">
            <%= @run.error_message %>
          </div>
        <% end %>

        <section class="section-card" style="margin-top: 1rem;">
          <div class="section-header">
            <h2 class="section-title">Transcript</h2>
            <%= if @transcript do %>
              <span class="muted"><%= length(@transcript.turns) %> turns</span>
            <% end %>
          </div>

          <%= if @transcript do %>
            <div class="event-stream" id="transcript-stream">
              <%= for turn <- @transcript.turns do %>
                <.render_turn turn={turn} />
              <% end %>
            </div>
          <% else %>
            <p class="empty-state">No transcript available. Session archive may not have been extracted yet.</p>
          <% end %>
        </section>
      <% else %>
        <section class="section-card" style="margin-top: 1rem;">
          <p class="empty-state">Run not found.</p>
        </section>
      <% end %>
    </section>
    """
  end

  # --- Transcript rendering ---

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

  defp load_transcript(run) do
    # Try specific session file first (exact match for this run)
    case try_specific_session(run) do
      {:ok, transcript} -> transcript
      :not_found -> try_archive(run) || try_live_read(run)
    end
  end

  # Load the exact session file recorded for this run
  defp try_specific_session(%{sandbox_id: sandbox_id, session_file: session_file})
       when is_binary(sandbox_id) and is_binary(session_file) and session_file != "" do
    case SessionReader.read_live_session(sandbox_id, session_file) do
      {:ok, summary} -> {:ok, summary}
      _ -> :not_found
    end
  rescue
    _ -> :not_found
  end

  defp try_specific_session(_), do: :not_found

  # Try archived sessions by sandbox name
  defp try_archive(run) do
    sandbox_name = run.sandbox_name || "karkhana-#{run.issue_identifier}"

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

  # Try live-read from sandbox (latest file)
  defp try_live_read(%{sandbox_id: sandbox_id}) when is_binary(sandbox_id) do
    case Karkhana.Bhatti.Client.exec(
           sandbox_id,
           ["bash", "-c", "ls -t /home/lohar/karkhana-sessions/*.jsonl 2>/dev/null | head -1"],
           timeout_sec: 5
         ) do
      {:ok, %{"exit_code" => 0, "stdout" => path}} when byte_size(path) > 0 ->
        case SessionReader.read_live_session(sandbox_id, String.trim(path)) do
          {:ok, summary} -> summary
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp try_live_read(_), do: nil

  # --- Formatters ---

  defp format_cost(nil), do: "0.00"
  defp format_cost(cost) when is_float(cost), do: :erlang.float_to_binary(cost, decimals: 2)
  defp format_cost(_), do: "0.00"

  defp format_duration(nil), do: "—"

  defp format_duration(secs) when is_number(secs) do
    m = div(trunc(secs), 60)
    s = rem(trunc(secs), 60)
    if m > 0, do: "#{m}m #{s}s", else: "#{s}s"
  end

  defp outcome_class(outcome) do
    case to_string(outcome) do
      "success" -> "outcome-success"
      "gate_failed" -> "outcome-gate-failed"
      _ -> "outcome-error"
    end
  end
end
