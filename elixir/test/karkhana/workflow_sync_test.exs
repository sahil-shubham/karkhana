defmodule Karkhana.WorkflowSyncTest do
  use ExUnit.Case, async: true

  alias Karkhana.Linear.WorkflowSync

  describe "WorkflowSync GenServer" do
    test "starts and responds to state_id queries" do
      {:ok, pid} = WorkflowSync.start_link(name: :"sync_test_#{System.unique_integer([:positive])}")

      # No states cached yet (sync hasn't run against real Linear)
      assert WorkflowSync.state_id(pid, "Planning") == nil
      assert WorkflowSync.state_ids(pid) == %{}

      GenServer.stop(pid)
    end

    test "state_id! raises when state not found" do
      {:ok, pid} = WorkflowSync.start_link(name: :"sync_test_raise_#{System.unique_integer([:positive])}")

      assert_raise RuntimeError, ~r/no cached state ID/, fn ->
        WorkflowSync.state_id!(pid, "NonexistentState")
      end

      GenServer.stop(pid)
    end
  end

  describe "sync result structure" do
    test "state_ids cache is a string → string map" do
      # Simulate what a successful sync would produce
      state_ids = %{
        "Todo" => "uuid-1",
        "Planning" => "uuid-2",
        "Plan Review" => "uuid-3",
        "Implementing" => "uuid-4",
        "In Review" => "uuid-5",
        "Done" => "uuid-6",
        "Cancelled" => "uuid-7"
      }

      assert is_map(state_ids)
      assert Map.get(state_ids, "Planning") == "uuid-2"
      assert Map.get(state_ids, "Nonexistent") == nil
    end
  end
end
