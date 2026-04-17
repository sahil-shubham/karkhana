defmodule Karkhana.Linear.Webhook do
  @moduledoc """
  Parses Linear webhook payloads into generic Tracker.Event structs.
  Handles HMAC signature verification.
  """

  alias Karkhana.Tracker.Event

  @doc """
  Verify the HMAC-SHA256 signature of a webhook payload.
  Returns :ok if valid, {:error, :invalid_signature} otherwise.
  """
  @spec verify_signature(binary(), String.t(), String.t()) :: :ok | {:error, :invalid_signature}
  def verify_signature(raw_body, signature, webhook_secret)
      when is_binary(raw_body) and is_binary(signature) and is_binary(webhook_secret) do
    expected = :crypto.mac(:hmac, :sha256, webhook_secret, raw_body) |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  def verify_signature(_, _, _), do: {:error, :invalid_signature}

  @doc """
  Parse a decoded webhook JSON payload into a Tracker.Event.
  Returns {:ok, event} or {:error, reason}.
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"type" => "Issue", "action" => action} = payload) do
    data = Map.get(payload, "data", %{})
    updated_from = Map.get(payload, "updatedFrom", %{})

    event_type = issue_event_type(action, data, updated_from)

    {:ok,
     %Event{
       type: event_type,
       issue_id: data["id"],
       issue_identifier: data["identifier"],
       data: %{
         action: action,
         title: data["title"],
         state: extract_state(data),
         labels: extract_labels(data),
         assignee_id: data["assigneeId"],
         description: data["description"],
         priority: data["priority"],
         updated_from: updated_from
       },
       source: :linear,
       timestamp: parse_timestamp(payload["createdAt"])
     }}
  end

  def parse(%{"type" => "Comment", "action" => _action} = payload) do
    data = Map.get(payload, "data", %{})

    {:ok,
     %Event{
       type: :issue_commented,
       issue_id: data["issueId"],
       issue_identifier: nil,
       data: %{
         comment_id: data["id"],
         body: data["body"],
         user_id: data["userId"]
       },
       source: :linear,
       timestamp: parse_timestamp(payload["createdAt"])
     }}
  end

  def parse(%{"type" => "IssueLabel"} = payload) do
    data = Map.get(payload, "data", %{})

    {:ok,
     %Event{
       type: :issue_labeled,
       issue_id: data["issueId"],
       issue_identifier: nil,
       data: %{label: data["name"]},
       source: :linear,
       timestamp: parse_timestamp(payload["createdAt"])
     }}
  end

  def parse(%{"type" => type}) do
    {:error, {:unsupported_webhook_type, type}}
  end

  def parse(_), do: {:error, :invalid_payload}

  # --- Private ---

  defp issue_event_type("create", _data, _updated_from), do: :issue_created

  defp issue_event_type("update", _data, updated_from) do
    cond do
      Map.has_key?(updated_from, "stateId") -> :issue_state_changed
      Map.has_key?(updated_from, "assigneeId") -> :issue_assigned
      true -> :issue_updated
    end
  end

  defp issue_event_type(_action, _data, _updated_from), do: :issue_updated

  defp extract_state(%{"state" => %{"name" => name}}), do: name
  defp extract_state(_), do: nil

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    Enum.map(labels, fn
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_labels(_), do: []

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()
end
