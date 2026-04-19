defmodule Karkhana do
  @moduledoc """
  Entry point for the Karkhana orchestrator.
  """

  @doc """
  Start the dispatcher in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Karkhana.Dispatcher.start_link(opts)
  end
end

defmodule Karkhana.Application do
  @moduledoc """
  OTP application entrypoint.

  Supervision tree:
  - PubSub: real-time event distribution
  - Registry: session lookup by issue identifier
  - Store: SQLite persistence
  - WorkflowStore: config hot-reload
  - WorkflowSync: Linear state sync
  - SessionSupervisor: DynamicSupervisor for Session processes
  - Dispatcher: polls Linear, starts sessions
  - HttpServer: Phoenix dashboard
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Karkhana.LogFile.configure()

    children = [
      {Phoenix.PubSub, name: Karkhana.PubSub},
      {Registry, keys: :unique, name: Karkhana.SessionRegistry},
      Karkhana.Store,
      Karkhana.WorkflowStore,
      Karkhana.Linear.WorkflowSync,
      Karkhana.SessionSupervisor,
      Karkhana.Dispatcher,
      Karkhana.HttpServer
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: Karkhana.Supervisor
    )
  end
end
