defmodule KarkhanaWeb.TranscriptLive do
  @moduledoc """
  Archived session transcript viewer.
  Reads JSONL files from extracted session archives.
  """

  use Phoenix.LiveView, layout: {KarkhanaWeb.Layouts, :app}

  alias Karkhana.SessionReader

  @impl true
  def mount(%{"sandbox" => sandbox}, _session, socket) do
    transcript =
      case SessionReader.list_sessions(sandbox) do
        [latest | _] ->
          case SessionReader.read_session(sandbox, latest) do
            {:ok, summary} -> summary
            _ -> nil
          end

        _ ->
          nil
      end

    socket =
      socket
      |> assign(:sandbox, sandbox)
      |> assign(:transcript, transcript)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card" style="padding: 1rem 1.5rem;">
        <a href="/" style="color: inherit; text-decoration: none; opacity: 0.6;">← Dashboard</a>
        <h1 class="hero-title" style="margin-top: 0.25rem; font-size: 1.5rem;">
          Transcript: <%= @sandbox %>
        </h1>
      </header>

      <%= if @transcript do %>
        <section class="section-card" style="margin-top: 1rem;">
          <div class="section-header">
            <h2 class="section-title">Session</h2>
            <span class="muted"><%= length(@transcript.turns) %> turns</span>
          </div>

          <div class="event-stream">
            <div :for={turn <- @transcript.turns} class={"event-row event-#{String.downcase(turn.role)}"}>
              <span class={"event-type-badge event-type-#{String.downcase(turn.role)}"}><%= turn.role %></span>
              <span class="event-summary">
                <%= if turn.tools != [] do %>
                  <div :for={tool <- turn.tools} style="font-size: 0.8rem; opacity: 0.7; margin-bottom: 0.25rem;">
                    🔧 <%= tool %>
                  </div>
                <% end %>
                <div style="white-space: pre-wrap; word-break: break-word;"><%= turn.text %></div>
              </span>
            </div>
          </div>
        </section>
      <% else %>
        <section class="section-card" style="margin-top: 1rem;">
          <p class="empty-state">No transcript found for sandbox "<%= @sandbox %>".</p>
        </section>
      <% end %>
    </section>
    """
  end
end
