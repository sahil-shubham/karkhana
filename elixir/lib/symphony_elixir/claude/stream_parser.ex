defmodule SymphonyElixir.Claude.StreamParser do
  @moduledoc """
  Parses newline-delimited JSON events from Claude Code's `--output-format stream-json`.
  """

  @spec parse_line(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = payload} -> {:ok, normalize_event(payload)}
      {:ok, _other} -> {:error, {:not_a_map, line}}
      {:error, reason} -> {:error, {:json_parse_error, reason, line}}
    end
  end

  @spec extract_session_id(map()) :: String.t() | nil
  def extract_session_id(%{"session_id" => id}) when is_binary(id), do: id
  def extract_session_id(_), do: nil

  @spec extract_usage(map()) :: map() | nil
  def extract_usage(event) do
    usage =
      Map.get(event, "usage") ||
        get_in(event, ["message", "usage"])

    normalize_usage(usage)
  end

  defp normalize_usage(%{} = usage) do
    input = get_int(usage, "input_tokens")
    output = get_int(usage, "output_tokens")

    if input || output do
      %{
        input_tokens: input || 0,
        output_tokens: output || 0,
        total_tokens: (input || 0) + (output || 0)
      }
    end
  end

  defp normalize_usage(_), do: nil

  defp normalize_event(payload) do
    type = Map.get(payload, "type", "unknown")
    subtype = Map.get(payload, "subtype")

    event_type =
      case {type, subtype} do
        {"system", "init"} -> :session_started
        {"system", _} -> :system
        {"assistant", _} -> :assistant
        {"tool", _} -> :tool_use
        {"result", _} -> :result
        {"error", _} -> :error
        _ -> :unknown
      end

    Map.put(payload, :event_type, event_type)
  end

  defp get_int(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) and v >= 0 -> v
      _ -> nil
    end
  end
end
