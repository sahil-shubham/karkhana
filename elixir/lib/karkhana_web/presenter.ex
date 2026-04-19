defmodule KarkhanaWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias Karkhana.{Config, Orchestrator, StatusDashboard, Store}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          completed_runs: Enum.map(Map.get(snapshot, :completed_runs, []), &run_payload/1),
          agent_totals: snapshot.agent_totals,
          rate_limits: snapshot.rate_limits,
          outcomes: outcome_summary(),
          methodology: methodology_stats(),
          lifecycle: lifecycle_summary()
        }

      :timeout ->
        %{
          generated_at: generated_at,
          error: %{code: "snapshot_timeout", message: "Snapshot timed out"}
        }

      :unavailable ->
        %{
          generated_at: generated_at,
          error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}
        }
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        agent_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    lifecycle = Config.settings!().lifecycle
    state_name = entry.state
    state_config = Karkhana.Config.Schema.Lifecycle.state_config(lifecycle, state_name)
    cost = Map.get(entry, :agent_cost_usd, 0.0)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      mode: Map.get(entry, :mode),
      state: state_name,
      lifecycle_type: state_config && state_config["type"],
      sandbox_id: Map.get(entry, :sandbox_id),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_agent_event,
      last_message: humanize_running_message(entry),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_agent_timestamp),
      tokens: %{
        input_tokens: entry.agent_input_tokens,
        output_tokens: entry.agent_output_tokens,
        total_tokens: entry.agent_total_tokens,
        cache_read: Map.get(entry, :agent_cache_read_tokens, 0)
      },
      cost_usd: cost,
      gate: Map.get(entry, :gate),
      gate_result: Map.get(entry, :gate_result)
    }
  end

  # Produce a useful one-liner from the agent's last event
  defp humanize_running_message(entry) do
    event = entry.last_agent_event
    raw = entry.last_agent_message

    cond do
      event in [:claude_starting, "claude_starting"] ->
        "Starting agent session…"

      event in [:session_started, "session_started"] ->
        sid = entry.session_id
        if sid, do: "Session started", else: "Starting…"

      event in [:tool_use, "tool_use"] ->
        extract_tool_summary(raw) || "Running tool…"

      event in [:assistant, "assistant"] ->
        extract_assistant_summary(raw) || "Thinking…"

      event in [:result, "result"] ->
        "Turn completed"

      event in [:turn_start, "turn_start"] ->
        "Turn starting…"

      event in [:turn_end, "turn_end"] ->
        "Turn ended"

      is_nil(event) ->
        "Waiting for first event…"

      true ->
        to_string(event)
    end
  end

  defp extract_tool_summary(%{message: raw}) when is_map(raw), do: extract_tool_summary(raw)

  defp extract_tool_summary(raw) when is_map(raw) do
    # Pi tool events: %{"type" => "tool_execution_start", "toolName" => "bash", "args" => %{"command" => "..."}}
    tool =
      Map.get(raw, "toolName") || Map.get(raw, "tool") ||
        Map.get(raw, :toolName) || Map.get(raw, :tool)

    args = Map.get(raw, "args") || Map.get(raw, :args) || %{}

    cond do
      is_binary(tool) and is_map(args) ->
        detail =
          Map.get(args, "command") || Map.get(args, "path") ||
            Map.get(args, :command) || Map.get(args, :path) || ""

        detail_str = detail |> to_string() |> String.split("\n") |> hd() |> String.slice(0, 100)
        "#{tool}: #{detail_str}"

      is_binary(tool) ->
        tool

      true ->
        nil
    end
  end

  defp extract_tool_summary(_), do: nil

  defp extract_assistant_summary(%{message: raw}) when is_map(raw),
    do: extract_assistant_summary(raw)

  defp extract_assistant_summary(raw) when is_map(raw) do
    # Pi message events: %{"message" => %{"content" => [%{"type" => "text", "text" => "..."}]}}
    # During thinking: content has [%{"type" => "thinking", "thinking" => "..."}]
    content =
      Map.get(raw, "content") ||
        get_in(raw, ["message", "content"]) ||
        Map.get(raw, :content)

    case content do
      blocks when is_list(blocks) ->
        text_block = Enum.find(blocks, fn b -> Map.get(b, "type") == "text" end)
        thinking_block = Enum.find(blocks, fn b -> Map.get(b, "type") == "thinking" end)

        cond do
          text_block && is_binary(Map.get(text_block, "text", "")) ->
            text_block["text"] |> String.replace("\n", " ") |> String.trim() |> String.slice(0, 120)

          thinking_block ->
            thinking = Map.get(thinking_block, "thinking", "")

            if is_binary(thinking) and byte_size(thinking) > 20 do
              snippet = thinking |> String.split("\n") |> List.last() |> String.trim() |> String.slice(0, 100)
              "\u{1F914} #{snippet}"
            else
              "\u{1F914} Thinking\u2026"
            end

          true ->
            nil
        end

      text when is_binary(text) ->
        text |> String.replace("\n", " ") |> String.trim() |> String.slice(0, 120)

      _ ->
        nil
    end
  end

  defp extract_assistant_summary(_), do: nil

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp run_payload(run) do
    %{
      issue_identifier: run.issue_identifier,
      mode: Map.get(run, :mode),
      config_hash: Map.get(run, :config_hash),
      attempt: run.attempt,
      tokens: run.tokens,
      cost_usd: run.cost_usd,
      duration_seconds: run.duration_seconds,
      outcome: run.outcome,
      error_message: humanize_error(run.error_message),
      error_raw: run.error_message,
      gate: Map.get(run, :gate),
      gate_result: Map.get(run, :gate_result),
      started_at: iso8601(run.started_at),
      ended_at: iso8601(run.ended_at)
    }
  end

  # Extract the useful part from RuntimeError stack trace strings
  defp humanize_error(nil), do: nil

  defp humanize_error(msg) when is_binary(msg) do
    cond do
      # "Agent run failed for ... : {:agent_error, "No API key for provider: anthropic"}"
      msg =~ "agent_error" ->
        case Regex.run(~r/agent_error.*?"([^"]+)"/, msg) do
          [_, error] -> error
          _ -> extract_core_error(msg)
        end

      # "Agent run failed for ... : {:http_error, 500, ...}"
      msg =~ "http_error" ->
        case Regex.run(~r/http_error,\s*(\d+)/, msg) do
          [_, code] -> "HTTP #{code} from bhatti API"
          _ -> extract_core_error(msg)
        end

      # Gate failures
      msg =~ "gate_failed" ->
        case Regex.run(~r/gate_failed.*?"([^"]+)"/, msg) do
          [_, detail] -> "Gate failed: #{detail}"
          _ -> "Gate check failed"
        end

      # "sandbox creation failed"
      msg =~ "sandbox" ->
        extract_core_error(msg)

      # Generic: extract the part after the last colon in the issue context
      true ->
        extract_core_error(msg)
    end
  end

  defp humanize_error(other), do: inspect(other)

  defp extract_core_error(msg) do
    # Try to get the part after "issue_identifier=XX-NN: "
    case Regex.run(~r/issue_identifier=\S+:\s*(.+?)"?\}?$/, msg) do
      [_, core] -> core |> String.slice(0, 200) |> String.trim()
      _ -> msg |> String.slice(0, 200) |> String.trim()
    end
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_agent_event,
      last_message: summarize_message(running.last_agent_message),
      last_event_at: iso8601(running.last_agent_timestamp),
      tokens: %{
        input_tokens: running.agent_input_tokens,
        output_tokens: running.agent_output_tokens,
        total_tokens: running.agent_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_agent_timestamp),
        event: running.last_agent_event,
        message: summarize_message(running.last_agent_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_agent_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp outcome_summary do
    case Karkhana.OutcomeTracker.scan_recent(days: 7) do
      {:ok, outcomes} ->
        summary = Karkhana.OutcomeTracker.summarize(outcomes)

        %{
          total: summary.total,
          zero_touch: summary.zero_touch,
          one_touch: summary.one_touch,
          multi_touch: summary.multi_touch,
          heavy_touch: summary.heavy_touch,
          zero_touch_rate: summary.zero_touch_rate
        }

      {:error, _} ->
        nil
    end
  end

  defp methodology_stats do
    case Store.run_stats() do
      {:ok, stats} ->
        config_events =
          case Store.list_config_events(limit: 10) do
            {:ok, events} -> events
            _ -> []
          end

        Map.put(stats, :recent_config_changes, config_events)

      {:error, _} ->
        nil
    end
  end

  defp lifecycle_summary do
    lifecycle = Config.settings!().lifecycle

    if lifecycle.states == %{} do
      nil
    else
      alias Karkhana.Config.Schema.Lifecycle

      %{
        auto_sync: lifecycle.auto_sync,
        dispatch_states: Lifecycle.dispatch_states(lifecycle),
        human_gate_states: Lifecycle.human_gate_states(lifecycle),
        terminal_states: Lifecycle.terminal_states(lifecycle),
        state_count: map_size(lifecycle.states)
      }
    end
  end
end
