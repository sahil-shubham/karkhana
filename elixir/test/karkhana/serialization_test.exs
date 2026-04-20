defmodule Karkhana.SerializationTest do
  @moduledoc """
  Tests that data crossing the Elixir → JSON boundary is serializable.
  Prevents regressions where internal types (PIDs, tuples, refs) leak
  into API responses or PubSub messages.
  """

  use ExUnit.Case, async: true

  alias Karkhana.Session
  alias Karkhana.Linear.Issue

  describe "session summary serialization" do
    test "summary with no gate results is JSON-serializable" do
      state = base_state()
      summary = Session.status_for_test(state)
      assert {:ok, json} = Jason.encode(summary)
      assert is_binary(json)
    end

    test "summary with passing gate results is JSON-serializable" do
      state = %{base_state() | gate_results: [{"plan-exists", :pass, "Artifact exists at /workspace/docs/PLAN.md"}]}
      summary = Session.status_for_test(state)
      assert {:ok, json} = Jason.encode(summary)
      assert is_binary(json)
    end

    test "summary with failing gate results is JSON-serializable" do
      state = %{
        base_state()
        | gate_results: [
            {"plan-document", :fail, "No document found on issue"},
            {"builds", :pass, "Exit 0"}
          ]
      }

      summary = Session.status_for_test(state)
      assert {:ok, json} = Jason.encode(summary)
      assert is_binary(json)
    end

    test "summary with nil gate results is JSON-serializable" do
      state = %{base_state() | gate_results: nil}
      summary = Session.status_for_test(state)
      assert {:ok, json} = Jason.encode(summary)
      assert is_binary(json)
    end

    test "summary with DateTime started_at is JSON-serializable" do
      state = %{base_state() | started_at: DateTime.utc_now()}
      summary = Session.status_for_test(state)
      assert {:ok, _} = Jason.encode(summary)
    end

    test "summary does not contain PIDs, refs, or ports" do
      state = base_state()
      summary = Session.status_for_test(state)

      walk_value(summary, fn value ->
        refute is_pid(value), "Summary contains a PID: #{inspect(value)}"
        refute is_reference(value), "Summary contains a ref: #{inspect(value)}"
        refute is_port(value), "Summary contains a port: #{inspect(value)}"
      end)
    end

    test "all summary field values are JSON-safe types" do
      state = %{
        base_state()
        | gate_results: [{"gate-1", :fail, "output"}],
          mode: "planning",
          sandbox_id: "sbx_123",
          session_id: "sess_456",
          error: "something failed"
      }

      summary = Session.status_for_test(state)

      # Every value should be encodable
      for {key, value} <- summary do
        assert {:ok, _} = Jason.encode(value),
               "Field #{inspect(key)} is not JSON-serializable: #{inspect(value)}"
      end
    end
  end

  describe "dispatcher info serialization" do
    test "dispatcher info with dispatched entries is JSON-serializable" do
      # Simulate what Dispatcher.info() returns AFTER the fix
      # PIDs are converted to strings via inspect()
      info = %{
        dispatched: %{
          "issue-1" => %{identifier: "ME-42", attempt: 0, pid: inspect(self())}
        },
        dispatched_count: 1,
        max_concurrent: 3,
        max_retries: 0,
        poll_interval_ms: 30_000
      }

      assert {:ok, _} = Jason.encode(info)
    end

    test "raw PIDs are not JSON-serializable (proves the fix is needed)" do
      info_with_raw_pid = %{pid: self()}
      assert {:error, _} = Jason.encode(info_with_raw_pid)
    end
  end

  describe "event serialization" do
    test "display event with tool_use raw data is JSON-serializable" do
      event = %{
        at: DateTime.utc_now(),
        type: :tool_use,
        summary: "bash: ls /workspace",
        raw: %{
          "type" => "tool_execution_end",
          "toolCallId" => "abc",
          "toolName" => "bash",
          "args" => %{"command" => "ls /workspace"},
          "result" => "file1.txt\nfile2.txt",
          "isError" => false,
          :event_type => :tool_use
        }
      }

      assert {:ok, _} = Jason.encode(event)
    end

    test "display event with assistant content blocks is JSON-serializable" do
      event = %{
        at: DateTime.utc_now(),
        type: :assistant,
        summary: "thinking...",
        raw: %{
          "type" => "message_update",
          "message" => %{
            "content" => [
              %{"type" => "thinking", "thinking" => "Let me analyze..."},
              %{"type" => "text", "text" => "Here's what I found."}
            ]
          },
          :event_type => :assistant
        }
      }

      assert {:ok, _} = Jason.encode(event)
    end
  end

  # --- Helpers ---

  defp base_state do
    %Session{
      issue: %Issue{
        id: "issue-test-99",
        identifier: "ME-99",
        title: "Test issue",
        description: nil,
        state: "Planning",
        url: "https://linear.app/test/ME-99",
        labels: [],
        assigned_to_worker: true
      },
      events: :queue.new(),
      event_count: 5,
      tokens: %{input: 100, output: 20, total: 120, cache_read: 0, cache_write: 0},
      cost_usd: 0.01,
      turn_count: 3,
      started_at: DateTime.utc_now(),
      status: :running,
      mode: "planning",
      sandbox_id: "sbx_abc",
      attempt: 0,
      gate_results: nil
    }
  end

  # Walk all values in a nested structure, calling fun on each leaf
  defp walk_value(%_{} = struct, fun) do
    # Structs (DateTime, etc.) are leaf values
    fun.(struct)
  end

  defp walk_value(map, fun) when is_map(map) do
    Enum.each(map, fn {_k, v} -> walk_value(v, fun) end)
  end

  defp walk_value(list, fun) when is_list(list) do
    Enum.each(list, &walk_value(&1, fun))
  end

  defp walk_value(tuple, fun) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.each(&walk_value(&1, fun))
  end

  defp walk_value(value, fun) do
    fun.(value)
  end
end
