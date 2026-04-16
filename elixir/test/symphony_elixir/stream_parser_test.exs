defmodule SymphonyElixir.Claude.StreamParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.StreamParser

  describe "parse_line/1" do
    test "parses valid JSON into a normalized event" do
      assert {:ok, %{:event_type => :session_started}} =
               StreamParser.parse_line(~s({"type":"session","id":"s1"}))
    end

    test "returns error for non-JSON" do
      assert {:error, {:json_parse_error, _, _}} = StreamParser.parse_line("not json")
    end

    test "returns error for non-map JSON" do
      assert {:error, {:not_a_map, _}} = StreamParser.parse_line("[1,2,3]")
    end
  end

  describe "extract_session_id/1" do
    test "extracts session_id from top-level field" do
      assert "abc" == StreamParser.extract_session_id(%{"session_id" => "abc"})
    end

    test "extracts id from pi session event" do
      assert "s1" == StreamParser.extract_session_id(%{"type" => "session", "id" => "s1"})
    end

    test "returns nil when no session id" do
      assert nil == StreamParser.extract_session_id(%{"type" => "message_update"})
    end
  end

  describe "extract_usage/1" do
    test "extracts pi-style usage with cache and cost" do
      event = %{
        "usage" => %{
          "input" => 1000,
          "output" => 500,
          "totalTokens" => 1500,
          "cacheRead" => 800,
          "cacheWrite" => 200,
          "cost" => %{"total" => 0.0035, "input" => 0.001, "output" => 0.002, "cacheRead" => 0.0004, "cacheWrite" => 0.0001}
        }
      }

      usage = StreamParser.extract_usage(event)
      assert usage.input_tokens == 1000
      assert usage.output_tokens == 500
      assert usage.total_tokens == 1500
      assert usage.cache_read_tokens == 800
      assert usage.cache_write_tokens == 200
      assert_in_delta usage.cost_usd, 0.0035, 0.0001
    end

    test "extracts claude-style usage (no cache/cost)" do
      event = %{
        "usage" => %{
          "input_tokens" => 2000,
          "output_tokens" => 1000,
          "total_tokens" => 3000
        }
      }

      usage = StreamParser.extract_usage(event)
      assert usage.input_tokens == 2000
      assert usage.output_tokens == 1000
      assert usage.total_tokens == 3000
      assert usage.cache_read_tokens == 0
      assert usage.cache_write_tokens == 0
      assert usage.cost_usd == 0.0
    end

    test "extracts usage from nested message.usage" do
      event = %{
        "message" => %{
          "usage" => %{"input" => 100, "output" => 50, "totalTokens" => 150}
        }
      }

      usage = StreamParser.extract_usage(event)
      assert usage.input_tokens == 100
      assert usage.output_tokens == 50
    end

    test "returns nil when no usage data" do
      assert nil == StreamParser.extract_usage(%{"type" => "agent_start"})
    end
  end

  describe "event normalization" do
    test "pi agent_start maps to session_started" do
      {:ok, event} = StreamParser.parse_line(~s({"type":"agent_start"}))
      assert event.event_type == :session_started
    end

    test "pi agent_end maps to result" do
      {:ok, event} = StreamParser.parse_line(~s({"type":"agent_end"}))
      assert event.event_type == :result
    end

    test "pi tool_execution_start maps to tool_use" do
      {:ok, event} = StreamParser.parse_line(~s({"type":"tool_execution_start"}))
      assert event.event_type == :tool_use
    end

    test "unknown type maps to unknown" do
      {:ok, event} = StreamParser.parse_line(~s({"type":"something_new"}))
      assert event.event_type == :unknown
    end
  end
end
