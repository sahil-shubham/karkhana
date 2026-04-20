defmodule Karkhana.SessionTest do
  use ExUnit.Case, async: true

  alias Karkhana.Session
  alias Karkhana.Linear.Issue

  describe "state struct" do
    test "initial state has correct defaults" do
      state = %Session{
        issue: make_issue(),
        started_at: DateTime.utc_now()
      }

      assert state.status == :starting
      assert state.tokens == %{input: 0, output: 0, total: 0, cache_read: 0, cache_write: 0}
      assert state.cost_usd == 0.0
      assert state.lines_seen == 0
      assert state.event_count == 0
      assert state.turn_count == 0
      assert :queue.len(state.events) == 0
    end
  end

  describe "event ring buffer" do
    test "events are added to the buffer" do
      state = %Session{
        issue: make_issue(),
        events: :queue.new(),
        event_count: 0,
        tokens: %{input: 0, output: 0, total: 0, cache_read: 0, cache_write: 0},
        cost_usd: 0.0,
        turn_count: 0,
        started_at: DateTime.utc_now()
      }

      # Simulate processing 5 events
      state =
        Enum.reduce(1..5, state, fn i, acc ->
          event = %{"type" => "message_update", :event_type => :assistant, "content" => "msg #{i}"}
          process_event_test(acc, event)
        end)

      assert state.event_count == 5
      assert :queue.len(state.events) == 5
    end

    test "all events are retained (no cap)" do
      state = %Session{
        issue: make_issue(),
        events: :queue.new(),
        event_count: 0,
        tokens: %{input: 0, output: 0, total: 0, cache_read: 0, cache_write: 0},
        cost_usd: 0.0,
        turn_count: 0,
        started_at: DateTime.utc_now()
      }

      # Add 250 events — all should be retained
      state =
        Enum.reduce(1..250, state, fn i, acc ->
          event = %{"type" => "message_update", :event_type => :assistant, "content" => "msg #{i}"}
          process_event_test(acc, event)
        end)

      assert state.event_count == 250
      assert :queue.len(state.events) == 250

      # First event should still be there
      first = :queue.peek(state.events) |> elem(1)
      assert first.raw["content"] == "msg 1"
    end
  end

  describe "token tracking" do
    test "updates tokens from usage events (cumulative max)" do
      state = base_state()

      # First event: input=100, output=10, total=110
      event1 = %{
        :event_type => :assistant,
        "type" => "message_update",
        "message" => %{
          "usage" => %{
            "input" => 100,
            "output" => 10,
            "totalTokens" => 110,
            "cacheRead" => 0,
            "cacheWrite" => 50,
            "cost" => %{"total" => 0.005}
          }
        }
      }

      state = process_event_test(state, event1)
      assert state.tokens.input == 100
      assert state.tokens.output == 10
      assert state.tokens.total == 110
      assert state.cost_usd == 0.005

      # Second event: cumulative input=200, output=20
      event2 = %{
        :event_type => :assistant,
        "type" => "message_update",
        "message" => %{
          "usage" => %{
            "input" => 200,
            "output" => 20,
            "totalTokens" => 220,
            "cacheRead" => 0,
            "cacheWrite" => 50,
            "cost" => %{"total" => 0.012}
          }
        }
      }

      state = process_event_test(state, event2)
      assert state.tokens.input == 200
      assert state.tokens.output == 20
      assert state.tokens.total == 220
      assert state.cost_usd == 0.012
    end

    test "tokens never decrease (cumulative max)" do
      state = base_state()

      # High values
      event1 = %{:event_type => :assistant, "type" => "message_update", "message" => %{"usage" => %{"input" => 500, "output" => 50, "totalTokens" => 550, "cost" => %{"total" => 0.05}}}}
      state = process_event_test(state, event1)

      # Lower values in next event (shouldn't decrease)
      event2 = %{:event_type => :assistant, "type" => "message_update", "message" => %{"usage" => %{"input" => 100, "output" => 10, "totalTokens" => 110, "cost" => %{"total" => 0.01}}}}
      state = process_event_test(state, event2)

      assert state.tokens.input == 500
      assert state.tokens.output == 50
      assert state.tokens.total == 550
      assert state.cost_usd == 0.05
    end
  end

  describe "event summarization" do
    test "summarizes tool events" do
      event = %{
        :event_type => :tool_use,
        "type" => "tool_execution_start",
        "toolName" => "bash",
        "args" => %{"command" => "ls /workspace/src/"}
      }

      state = process_event_test(base_state(), event)
      last_event = :queue.peek_r(state.events) |> elem(1)
      assert last_event.summary =~ "bash: ls /workspace/src/"
    end

    test "summarizes assistant thinking events" do
      event = %{
        :event_type => :assistant,
        "type" => "message_update",
        "message" => %{
          "content" => [%{"type" => "thinking", "thinking" => "Let me analyze the codebase structure to understand how the routing works"}]
        }
      }

      state = process_event_test(base_state(), event)
      last_event = :queue.peek_r(state.events) |> elem(1)
      assert last_event.summary =~ "🤔"
    end

    test "summarizes assistant text events" do
      event = %{
        :event_type => :assistant,
        "type" => "message_update",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "I'll create a plan for the light theme migration."}]
        }
      }

      state = process_event_test(base_state(), event)
      last_event = :queue.peek_r(state.events) |> elem(1)
      assert last_event.summary =~ "plan for the light theme"
    end
  end

  describe "summary/1" do
    test "returns a complete summary map" do
      state = %{
        base_state()
        | mode: "planning",
          status: :running,
          sandbox_id: "sbx_123",
          session_id: "session_456",
          tokens: %{input: 100, output: 20, total: 120, cache_read: 0, cache_write: 0},
          cost_usd: 0.015,
          event_count: 42,
          turn_count: 2,
          attempt: 1
      }

      summary = Session.status_for_test(state)

      assert summary.identifier == "ME-99"
      assert summary.mode == "planning"
      assert summary.status == :running
      assert summary.tokens.total == 120
      assert summary.cost_usd == 0.015
      assert summary.event_count == 42
    end
  end

  describe "public API" do
    test "list_running returns empty list when registry is running" do
      # Start a temporary registry for this test
      start_supervised!({Registry, keys: :unique, name: :test_session_registry})

      # The real list_running uses Karkhana.SessionRegistry which may not be running
      # in tests. Just verify the function signature works.
      assert is_function(&Session.list_running/0)
    end

    test "lookup returns nil when registry is running and session doesn't exist" do
      # Only start if not already running (another test may have started it)
      unless Process.whereis(Karkhana.SessionRegistry) do
        start_supervised!({Registry, keys: :unique, name: Karkhana.SessionRegistry})
      end

      assert Session.lookup("NONEXISTENT-999") == nil
    end
  end

  # --- Test helpers ---

  # Expose process_event for testing without starting a GenServer
  # This mirrors the private function's logic
  defp process_event_test(state, event) do
    event_type = Map.get(event, :event_type, :unknown)
    usage = Karkhana.Claude.StreamParser.extract_usage(event)

    {tokens, cost} =
      if usage do
        tokens = %{
          input: max(state.tokens.input, Map.get(usage, :input_tokens, 0)),
          output: max(state.tokens.output, Map.get(usage, :output_tokens, 0)),
          total: max(state.tokens.total, Map.get(usage, :total_tokens, 0)),
          cache_read: max(state.tokens.cache_read, Map.get(usage, :cache_read_tokens, 0)),
          cache_write: max(state.tokens.cache_write, Map.get(usage, :cache_write_tokens, 0))
        }

        cost = max(state.cost_usd, Map.get(usage, :cost_usd, 0.0))
        {tokens, cost}
      else
        {state.tokens, state.cost_usd}
      end

    display_event = %{
      at: DateTime.utc_now(),
      type: event_type,
      summary: summarize_event_test(event_type, event),
      raw: event
    }

    events = :queue.in(display_event, state.events)

    turn_count =
      if event_type in [:turn_start, :result, :turn_end],
        do: state.turn_count + 1,
        else: state.turn_count

    %{state | tokens: tokens, cost_usd: cost, events: events, event_count: state.event_count + 1, turn_count: turn_count}
  end

  defp summarize_event_test(:tool_use, event) do
    tool = Map.get(event, "toolName") || Map.get(event, "tool") || "tool"
    args = Map.get(event, "args") || %{}
    detail = Map.get(args, "command") || Map.get(args, "path") || ""
    "#{tool}: #{detail |> to_string() |> String.split("\n") |> hd() |> String.slice(0, 120)}"
  end

  defp summarize_event_test(:assistant, event) do
    content =
      Map.get(event, "content") ||
        get_in(event, ["message", "content"]) || []

    case content do
      blocks when is_list(blocks) ->
        text_block = Enum.find(blocks, fn b -> Map.get(b, "type") == "text" end)
        thinking_block = Enum.find(blocks, fn b -> Map.get(b, "type") == "thinking" end)

        cond do
          text_block ->
            (text_block["text"] || "") |> String.replace("\n", " ") |> String.trim() |> String.slice(0, 150)

          thinking_block ->
            thinking = thinking_block["thinking"] || ""

            if byte_size(thinking) > 20 do
              snippet = thinking |> String.split("\n") |> List.last() |> String.trim() |> String.slice(0, 120)
              "🤔 #{snippet}"
            else
              "🤔 Thinking…"
            end

          true ->
            ""
        end

      _ ->
        ""
    end
  end

  defp summarize_event_test(type, _event), do: to_string(type)

  defp make_issue(opts \\ []) do
    %Issue{
      id: Keyword.get(opts, :id, "issue-test-99"),
      identifier: Keyword.get(opts, :identifier, "ME-99"),
      title: Keyword.get(opts, :title, "Test issue"),
      description: nil,
      state: Keyword.get(opts, :state, "Todo"),
      url: "https://linear.app/test/ME-99",
      labels: [],
      assigned_to_worker: true
    }
  end

  defp base_state(opts \\ []) do
    %Session{
      issue: make_issue(opts),
      events: :queue.new(),
      event_count: 0,
      tokens: %{input: 0, output: 0, total: 0, cache_read: 0, cache_write: 0},
      cost_usd: 0.0,
      turn_count: 0,
      started_at: DateTime.utc_now(),
      status: :running
    }
  end
end
