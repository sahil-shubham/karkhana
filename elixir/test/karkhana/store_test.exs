defmodule Karkhana.StoreTest do
  use ExUnit.Case, async: false

  alias Karkhana.Store

  @test_db_dir Path.join(System.tmp_dir!(), "karkhana-store-test")

  setup do
    File.mkdir_p!(@test_db_dir)
    path = Path.join(@test_db_dir, "test-#{System.unique_integer([:positive])}.db")

    # Stop any existing store from a previous test
    if pid = Process.whereis(Karkhana.Store), do: GenServer.stop(pid)

    {:ok, pid} = Store.start_link(path: path)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(path)
    end)

    %{pid: pid, path: path}
  end

  describe "runs" do
    test "insert and list round-trip", %{pid: _pid} do
      run = sample_run("TST-1")
      assert :ok = Store.insert_run(run)

      assert {:ok, [stored]} = Store.list_runs()
      assert stored.issue_identifier == "TST-1"
      assert stored.mode == "planning"
      assert stored.config_hash == "abc123"
      assert stored.outcome == "success"
      assert stored.tokens.input == 1000
      assert stored.tokens.output == 500
      assert stored.tokens.cache_read == 800
      assert stored.tokens.total == 1500
      assert stored.cost_usd == 4.50
      assert stored.labels == ["plan"]
      assert stored.gate == "plan-ready"
      assert stored.gate_result == "pass"
      assert stored.artifacts_before == []
      assert stored.artifacts_after == ["plan"]
    end

    test "list filters by mode", %{pid: _pid} do
      Store.insert_run(sample_run("TST-2", mode: "planning"))
      Store.insert_run(sample_run("TST-3", mode: "implementation"))
      Store.insert_run(sample_run("TST-4", mode: "planning"))

      assert {:ok, plans} = Store.list_runs(mode: "planning")
      assert length(plans) == 2
      assert Enum.all?(plans, &(&1.mode == "planning"))

      assert {:ok, impls} = Store.list_runs(mode: "implementation")
      assert length(impls) == 1
    end

    test "list filters by issue_identifier", %{pid: _pid} do
      Store.insert_run(sample_run("TST-5"))
      Store.insert_run(sample_run("TST-5"))
      Store.insert_run(sample_run("TST-6"))

      assert {:ok, runs} = Store.list_runs(issue_identifier: "TST-5")
      assert length(runs) == 2
    end

    test "list respects limit", %{pid: _pid} do
      for i <- 1..10, do: Store.insert_run(sample_run("TST-L#{i}"))

      assert {:ok, runs} = Store.list_runs(limit: 3)
      assert length(runs) == 3
    end

    test "list returns most recent first", %{pid: _pid} do
      Store.insert_run(sample_run("TST-OLD", started_at: ~U[2026-01-01 00:00:00Z]))
      Store.insert_run(sample_run("TST-NEW", started_at: ~U[2026-04-01 00:00:00Z]))

      assert {:ok, [first | _]} = Store.list_runs()
      assert first.issue_identifier == "TST-NEW"
    end
  end

  describe "config_events" do
    test "insert and list round-trip", %{pid: _pid} do
      event = %{
        config_hash: "hash_new",
        previous_hash: "hash_old",
        changed_files: ["modes/planning.md"],
        snapshot: %{"agent_command" => "pi"}
      }

      assert :ok = Store.insert_config_event(event)
      assert {:ok, [stored]} = Store.list_config_events()
      assert stored.config_hash == "hash_new"
      assert stored.previous_hash == "hash_old"
      assert stored.changed_files == ["modes/planning.md"]
      assert stored.snapshot == %{"agent_command" => "pi"}
    end
  end

  describe "issue_events" do
    test "insert and list by issue", %{pid: _pid} do
      Store.insert_issue_event(%{
        issue_id: "id1",
        issue_identifier: "TST-10",
        event: :dispatched,
        mode: "planning",
        config_hash: "abc",
        metadata: %{attempt: 1}
      })

      Store.insert_issue_event(%{
        issue_id: "id1",
        issue_identifier: "TST-10",
        event: :completed,
        mode: "planning",
        config_hash: "abc",
        metadata: %{outcome: "success"}
      })

      Store.insert_issue_event(%{
        issue_id: "id2",
        issue_identifier: "TST-11",
        event: :dispatched,
        mode: "implementation",
        config_hash: "def",
        metadata: nil
      })

      assert {:ok, events} = Store.list_issue_events("TST-10")
      assert length(events) == 2
      assert Enum.at(events, 0).event == "dispatched"
      assert Enum.at(events, 1).event == "completed"
    end
  end

  describe "run_stats" do
    test "computes aggregates", %{pid: _pid} do
      Store.insert_run(sample_run("TST-S1", mode: "planning", cost_usd: 5.0, gate: "plan-ready", gate_result: "pass"))
      Store.insert_run(sample_run("TST-S2", mode: "planning", cost_usd: 3.0, gate: "plan-ready", gate_result: "fail"))
      Store.insert_run(sample_run("TST-S3", mode: "implementation", cost_usd: 10.0, gate: "tests-pass", gate_result: "pass"))

      assert {:ok, stats} = Store.run_stats()
      assert stats.total == 3
      assert stats.by_mode["planning"] == 2
      assert stats.by_mode["implementation"] == 1
      assert stats.gate_pass_rate["plan-ready"] == 0.5
      assert stats.gate_pass_rate["tests-pass"] == 1.0
    end

    test "handles empty store", %{pid: _pid} do
      assert {:ok, stats} = Store.run_stats()
      assert stats.total == 0
      assert stats.by_mode == %{}
    end
  end

  describe "persistence" do
    test "data survives restart", %{pid: pid, path: path} do
      Store.insert_run(sample_run("TST-P1"))
      GenServer.stop(pid)

      {:ok, _pid2} = Store.start_link(path: path)
      assert {:ok, [run]} = Store.list_runs()
      assert run.issue_identifier == "TST-P1"
    end
  end

  # --- Helpers ---

  defp sample_run(identifier, overrides \\ []) do
    %{
      issue_id: "issue_#{identifier}",
      issue_identifier: identifier,
      mode: Keyword.get(overrides, :mode, "planning"),
      config_hash: Keyword.get(overrides, :config_hash, "abc123"),
      attempt: 0,
      sandbox_id: "sbx_123",
      sandbox_name: "karkhana-#{identifier}",
      session_id: "sess_123",
      tokens: %{
        input: 1000,
        output: 500,
        cache_read: 800,
        cache_write: 200,
        total: 1500
      },
      cost_usd: Keyword.get(overrides, :cost_usd, 4.50),
      duration_seconds: 120.0,
      outcome: :success,
      error_message: nil,
      artifacts_before: [],
      artifacts_after: ["plan"],
      gate: Keyword.get(overrides, :gate, "plan-ready"),
      gate_result: Keyword.get(overrides, :gate_result, "pass"),
      gate_output: "GATE PASS",
      labels: ["plan"],
      started_at: Keyword.get(overrides, :started_at, DateTime.utc_now()),
      ended_at: DateTime.utc_now()
    }
  end
end
