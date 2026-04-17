defmodule KarkhanaWeb.WebhookController do
  @moduledoc """
  Receives webhook pushes from Linear and forwards them to the orchestrator
  as generic Tracker.Event structs.
  """

  use Phoenix.Controller, formats: [:json]
  require Logger

  alias Karkhana.Linear.Webhook

  @doc """
  POST /webhooks/linear

  Verifies the HMAC signature, parses the payload into a Tracker.Event,
  and pushes it to the orchestrator. Always returns 200 to Linear
  (even on parse errors — Linear will retry on non-200, and we don't
  want retries for payloads we intentionally skip).
  """
  def linear(conn, _params) do
    with {:ok, raw_body} <- read_raw_body(conn),
         :ok <- verify_signature(conn, raw_body),
         {:ok, payload} <- Jason.decode(raw_body),
         {:ok, event} <- Webhook.parse(payload) do
      Logger.info("Webhook received: #{event.type} issue=#{event.issue_identifier || event.issue_id} source=#{event.source}")

      send(orchestrator(), {:tracker_event, event})

      Karkhana.Store.insert_issue_event(%{
        issue_id: event.issue_id,
        issue_identifier: event.issue_identifier || "unknown",
        event: event.type,
        mode: nil,
        config_hash: nil,
        metadata: %{source: event.source, data: event.data}
      })

      conn |> put_status(200) |> json(%{ok: true})
    else
      {:error, :invalid_signature} ->
        Logger.warning("Webhook rejected: invalid signature")
        conn |> put_status(401) |> json(%{error: "invalid signature"})

      {:error, {:unsupported_webhook_type, type}} ->
        Logger.debug("Webhook skipped: unsupported type #{type}")
        conn |> put_status(200) |> json(%{ok: true, skipped: type})

      {:error, reason} ->
        Logger.warning("Webhook error: #{inspect(reason)}")
        conn |> put_status(200) |> json(%{ok: true, error: inspect(reason)})
    end
  end

  defp read_raw_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) ->
        {:ok, body}

      _ ->
        # Fallback: re-read (only works if body hasn't been consumed)
        case Plug.Conn.read_body(conn) do
          {:ok, body, _conn} -> {:ok, body}
          {:more, _body, _conn} -> {:error, :body_too_large}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp verify_signature(conn, raw_body) do
    signature = Plug.Conn.get_req_header(conn, "linear-signature") |> List.first()
    secret = webhook_secret()

    cond do
      is_nil(secret) or secret == "" ->
        # No secret configured — skip verification (dev mode)
        Logger.debug("Webhook signature verification skipped: no secret configured")
        :ok

      is_nil(signature) ->
        {:error, :invalid_signature}

      true ->
        Webhook.verify_signature(raw_body, signature, secret)
    end
  end

  defp webhook_secret do
    System.get_env("LINEAR_WEBHOOK_SECRET")
  end

  defp orchestrator do
    Karkhana.Orchestrator
  end
end
