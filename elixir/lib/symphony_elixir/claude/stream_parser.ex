defmodule SymphonyElixir.Claude.StreamParser do
  @moduledoc """
  Parses newline-delimited JSON events from the coding agent's output.
  Supports both Claude Code (`--output-format stream-json`) and
  pi (`--mode json`) event formats.
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
  # pi puts session id in the "session" event
  def extract_session_id(%{"type" => "session", "id" => id}) when is_binary(id), do: id
  def extract_session_id(_), do: nil

  @spec extract_usage(map()) :: map() | nil
  def extract_usage(event) do
    # pi: usage is nested in message_update -> message -> usage
    # claude: usage is at top level or in message.usage
    usage =
      Map.get(event, "usage") ||
        get_in(event, ["message", "usage"]) ||
        get_in(event, ["assistantMessageEvent", "message", "usage"])

    normalize_usage(usage)
  end

  defp normalize_usage(%{} = usage) do
    # pi uses "input"/"output"/"totalTokens"/"cacheRead"/"cacheWrite",
    # claude uses "input_tokens"/"output_tokens"
    input = get_int(usage, "input_tokens") || get_int(usage, "input")
    output = get_int(usage, "output_tokens") || get_int(usage, "output")
    cache_read = get_int(usage, "cacheRead") || get_int(usage, "cache_read_tokens") || 0
    cache_write = get_int(usage, "cacheWrite") || get_int(usage, "cache_write_tokens") || 0
    total = get_int(usage, "total_tokens") || get_int(usage, "totalTokens")

    # Pi nests cost as usage.cost.total (dollars)
    cost_map = Map.get(usage, "cost")
    cost_usd = if is_map(cost_map), do: get_float(cost_map, "total"), else: nil

    if input || output || total do
      %{
        input_tokens: input || 0,
        output_tokens: output || 0,
        cache_read_tokens: cache_read,
        cache_write_tokens: cache_write,
        total_tokens: total || (input || 0) + (output || 0),
        cost_usd: cost_usd || 0.0
      }
    end
  end

  defp normalize_usage(_), do: nil

  defp normalize_event(payload) do
    type = Map.get(payload, "type", "unknown")
    subtype = Map.get(payload, "subtype")

    event_type =
      case {type, subtype} do
        # Claude events
        {"system", "init"} -> :session_started
        {"system", _} -> :system
        {"assistant", _} -> :assistant
        {"tool", _} -> :tool_use
        {"result", _} -> :result
        {"error", _} -> :error
        # pi events
        {"session", _} -> :session_started
        {"agent_start", _} -> :session_started
        {"agent_end", _} -> :result
        {"turn_start", _} -> :turn_start
        {"turn_end", _} -> :turn_end
        {"message_start", _} -> :assistant
        {"message_update", _} -> :assistant
        {"message_end", _} -> :assistant
        {"tool_execution_start", _} -> :tool_use
        {"tool_execution_update", _} -> :tool_use
        {"tool_execution_end", _} -> :tool_use
        _ -> :unknown
      end

    Map.put(payload, :event_type, event_type)
  end

  defp get_int(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) and v >= 0 -> v
      v when is_float(v) and v >= 0 -> round(v)
      _ -> nil
    end
  end

  defp get_float(map, key) do
    case Map.get(map, key) do
      v when is_float(v) -> v
      v when is_integer(v) -> v * 1.0
      _ -> nil
    end
  end
end
