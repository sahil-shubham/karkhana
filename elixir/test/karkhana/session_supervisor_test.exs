defmodule Karkhana.SessionSupervisorTest do
  use ExUnit.Case, async: true

  alias Karkhana.SessionSupervisor

  describe "supervisor" do
    test "starts successfully" do
      name = :"sup_test_#{System.unique_integer([:positive])}"
      assert {:ok, pid} = SessionSupervisor.start_link(name: name)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "count_sessions returns 0 when empty" do
      name = :"sup_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = SessionSupervisor.start_link(name: name)
      assert SessionSupervisor.count_sessions(pid) == 0
      GenServer.stop(pid)
    end
  end

  describe "registry" do
    test "registry starts and supports unique lookups" do
      reg_name = :"reg_test_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: reg_name})

      # Register a test process
      {:ok, _} = Registry.register(reg_name, "ME-42", :worker)
      me = self()
      assert [{^me, :worker}] = Registry.lookup(reg_name, "ME-42")
      assert [] = Registry.lookup(reg_name, "ME-99")
    end

    test "duplicate registration returns error" do
      reg_name = :"reg_test_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: reg_name})

      {:ok, _} = Registry.register(reg_name, "ME-42", :worker)
      assert {:error, {:already_registered, _}} = Registry.register(reg_name, "ME-42", :worker)
    end

    test "process exit unregisters from registry" do
      reg_name = :"reg_test_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: reg_name})

      # Spawn a process that registers then exits
      test_pid = self()

      pid =
        spawn(fn ->
          {:ok, _} = Registry.register(reg_name, "ME-42", :worker)
          send(test_pid, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered
      assert [{^pid, :worker}] = Registry.lookup(reg_name, "ME-42")

      # Kill the process
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Registry should be cleaned up
      assert [] = Registry.lookup(reg_name, "ME-42")
    end
  end
end
