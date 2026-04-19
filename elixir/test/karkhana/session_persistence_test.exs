defmodule Karkhana.SessionPersistenceTest do
  use ExUnit.Case

  alias Karkhana.Store

  setup do
    # Use a fresh in-memory store for isolation
    {:ok, store} = Store.start_link(name: :"persist_test_#{System.unique_integer([:positive])}", path: ":memory:")

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)
    end)

    %{store: store}
  end

  describe "active_sessions persistence" do
    test "upsert and list round-trips", %{store: store} do
      session = %{
        issue_id: "issue-1",
        issue_identifier: "ME-42",
        issue_json: ~s({"title":"Test issue","state":"Planning"}),
        sandbox_id: "sbx_abc",
        sandbox_name: "karkhana-ME-42",
        mode: "planning",
        output_file: "/tmp/bhatti-exec-abc.log",
        lines_seen: 0,
        session_id: nil,
        tokens_input: 0,
        tokens_output: 0,
        tokens_total: 0,
        tokens_cache_read: 0,
        cost_usd: 0.0,
        attempt: 0,
        started_at: DateTime.utc_now()
      }

      assert :ok = GenServer.call(store, {:upsert_active_session, session})

      {:ok, sessions} = GenServer.call(store, :list_active_sessions)
      assert length(sessions) == 1
      assert hd(sessions).issue_identifier == "ME-42"
      assert hd(sessions).sandbox_id == "sbx_abc"
    end

    test "upsert updates existing session", %{store: store} do
      session = %{
        issue_id: "issue-1",
        issue_identifier: "ME-42",
        issue_json: "{}",
        sandbox_id: "sbx_abc",
        sandbox_name: "karkhana-ME-42",
        mode: "planning",
        output_file: "/tmp/out.log",
        lines_seen: 0,
        tokens_input: 100,
        tokens_output: 10,
        tokens_total: 110,
        tokens_cache_read: 0,
        cost_usd: 0.01,
        attempt: 0,
        started_at: DateTime.utc_now()
      }

      assert :ok = GenServer.call(store, {:upsert_active_session, session})

      # Update with new token counts
      updated = %{session | lines_seen: 50, tokens_input: 500, tokens_total: 550, cost_usd: 0.05}
      assert :ok = GenServer.call(store, {:upsert_active_session, updated})

      {:ok, sessions} = GenServer.call(store, :list_active_sessions)
      assert length(sessions) == 1
      assert hd(sessions).lines_seen == 50
      assert hd(sessions).tokens_input == 500
      assert hd(sessions).cost_usd == 0.05
    end

    test "delete removes session", %{store: store} do
      session = %{
        issue_id: "issue-1",
        issue_identifier: "ME-42",
        issue_json: "{}",
        sandbox_id: "sbx_abc",
        sandbox_name: "karkhana-ME-42",
        mode: "planning",
        lines_seen: 0,
        tokens_input: 0,
        tokens_output: 0,
        tokens_total: 0,
        tokens_cache_read: 0,
        cost_usd: 0.0,
        attempt: 0,
        started_at: DateTime.utc_now()
      }

      :ok = GenServer.call(store, {:upsert_active_session, session})
      {:ok, [_]} = GenServer.call(store, :list_active_sessions)

      :ok = GenServer.call(store, {:delete_active_session, "issue-1"})
      {:ok, sessions} = GenServer.call(store, :list_active_sessions)
      assert sessions == []
    end

    test "list returns empty when no sessions", %{store: store} do
      {:ok, sessions} = GenServer.call(store, :list_active_sessions)
      assert sessions == []
    end

    test "multiple sessions coexist", %{store: store} do
      for i <- 1..3 do
        session = %{
          issue_id: "issue-#{i}",
          issue_identifier: "ME-#{i}",
          issue_json: "{}",
          sandbox_id: "sbx_#{i}",
          sandbox_name: "karkhana-ME-#{i}",
          mode: "planning",
          lines_seen: 0,
          tokens_input: 0,
          tokens_output: 0,
          tokens_total: 0,
          tokens_cache_read: 0,
          cost_usd: 0.0,
          attempt: 0,
          started_at: DateTime.utc_now()
        }

        :ok = GenServer.call(store, {:upsert_active_session, session})
      end

      {:ok, sessions} = GenServer.call(store, :list_active_sessions)
      assert length(sessions) == 3

      # Delete one
      :ok = GenServer.call(store, {:delete_active_session, "issue-2"})
      {:ok, sessions} = GenServer.call(store, :list_active_sessions)
      assert length(sessions) == 2
      identifiers = Enum.map(sessions, & &1.issue_identifier)
      assert "ME-1" in identifiers
      assert "ME-3" in identifiers
      refute "ME-2" in identifiers
    end
  end
end
