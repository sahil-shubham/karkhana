defmodule Karkhana.Claude.StreamParserTest do
  use ExUnit.Case, async: true

  alias Karkhana.Claude.StreamParser

  describe "parse_line/1" do
    test "parses valid JSON into a normalized event" do
      assert {:ok, %{:event_type => :session_started}} =
               StreamParser.parse_line(~s({"type":"session","id":"s1"}))
    end

    test "returns error for non-JSON (agent stderr mixed in)" do
      # Pi sometimes writes startup warnings to stdout before JSON stream begins
      assert {:error, {:json_parse_error, _, _}} =
               StreamParser.parse_line("Warning: Node.js version mismatch")
    end

    test "handles empty lines" do
      assert {:error, {:json_parse_error, _, _}} = StreamParser.parse_line("")
    end

    test "handles JSON arrays (not maps)" do
      assert {:error, {:not_a_map, _}} = StreamParser.parse_line("[1,2,3]")
    end
  end

  describe "extract_usage/1 - Pi format" do
    # Pi's actual message_end event shape (from packages/ai/src/types.ts Usage interface)
    test "extracts full Pi usage with cache and cost" do
      event = %{
        "type" => "message_end",
        "message" => %{
          "role" => "assistant",
          "usage" => %{
            "input" => 12500,
            "output" => 3200,
            "totalTokens" => 15700,
            "cacheRead" => 10000,
            "cacheWrite" => 2500,
            "cost" => %{
              "input" => 0.0375,
              "output" => 0.048,
              "cacheRead" => 0.005,
              "cacheWrite" => 0.009375,
              "total" => 0.099875
            }
          }
        }
      }

      usage = StreamParser.extract_usage(event)
      assert usage.input_tokens == 12500
      assert usage.output_tokens == 3200
      assert usage.total_tokens == 15700
      assert usage.cache_read_tokens == 10000
      assert usage.cache_write_tokens == 2500
      assert_in_delta usage.cost_usd, 0.099875, 0.000001
    end

    test "handles zero cache (first turn, nothing cached)" do
      event = %{
        "usage" => %{
          "input" => 5000,
          "output" => 1000,
          "totalTokens" => 6000,
          "cacheRead" => 0,
          "cacheWrite" => 5000,
          "cost" => %{"total" => 0.025}
        }
      }

      usage = StreamParser.extract_usage(event)
      assert usage.cache_read_tokens == 0
      assert usage.cache_write_tokens == 5000
    end

    test "handles missing cost field gracefully" do
      event = %{
        "usage" => %{"input" => 100, "output" => 50, "totalTokens" => 150}
      }

      usage = StreamParser.extract_usage(event)
      assert usage.input_tokens == 100
      assert usage.cost_usd == 0.0
      assert usage.cache_read_tokens == 0
    end
  end

  describe "extract_usage/1 - non-usage events" do
    test "returns nil for tool_execution events (no usage)" do
      event = %{
        "type" => "tool_execution_start",
        "toolCallId" => "tc_1",
        "toolName" => "bash"
      }

      assert nil == StreamParser.extract_usage(event)
    end

    test "returns nil for agent_start" do
      assert nil == StreamParser.extract_usage(%{"type" => "agent_start"})
    end
  end

  describe "extract_session_id/1" do
    test "extracts from pi session event (the actual shape Pi emits)" do
      # Pi emits this at session start
      assert "abc-123" == StreamParser.extract_session_id(%{"type" => "session", "id" => "abc-123"})
    end

    test "returns nil for events without session info" do
      assert nil == StreamParser.extract_session_id(%{"type" => "turn_start", "turnIndex" => 0})
    end
  end

  describe "event normalization edge cases" do
    test "events without type field get type unknown" do
      {:ok, event} = StreamParser.parse_line(~s({"data":"some payload"}))
      assert event.event_type == :unknown
    end

    test "preserves all original fields alongside event_type" do
      {:ok, event} = StreamParser.parse_line(~s({"type":"message_end","message":{"role":"assistant"}}))
      assert event.event_type == :assistant
      assert event["message"]["role"] == "assistant"
      assert event["type"] == "message_end"
    end
  end
end
