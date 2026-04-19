defmodule KarkhanaWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Karkhana observability data.
  Reads from Store and Session processes — no Orchestrator dependency.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias Karkhana.{Dispatcher, Session, Store}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    sessions =
      Session.list_running()
      |> Enum.reduce(%{}, fn id, acc ->
        case Session.lookup(id) do
          nil ->
            acc

          pid ->
            try do
              Map.put(acc, id, Session.status(pid))
            catch
              :exit, _ -> acc
            end
        end
      end)

    recent_runs =
      case Store.list_runs(limit: 20) do
        {:ok, runs} -> runs
        _ -> []
      end

    stats =
      case Store.run_stats() do
        {:ok, s} -> s
        _ -> %{}
      end

    dispatcher_info =
      try do
        Dispatcher.info()
      catch
        :exit, _ -> %{}
      end

    json(conn, %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      sessions: sessions,
      recent_runs: recent_runs,
      stats: stats,
      dispatcher: dispatcher_info
    })
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => identifier}) do
    session_data =
      case Session.lookup(identifier) do
        nil ->
          nil

        pid ->
          try do
            %{
              status: Session.status(pid),
              events: Session.events(pid, 100)
            }
          catch
            :exit, _ -> nil
          end
      end

    runs =
      case Store.list_runs(issue_identifier: identifier, limit: 10) do
        {:ok, runs} -> runs
        _ -> []
      end

    if is_nil(session_data) and runs == [] do
      error_response(conn, 404, "issue_not_found", "Issue not found")
    else
      json(conn, %{
        issue_identifier: identifier,
        session: session_data,
        runs: runs
      })
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    Dispatcher.refresh()

    conn
    |> put_status(202)
    |> json(%{queued: true, requested_at: DateTime.utc_now() |> DateTime.to_iso8601()})
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
