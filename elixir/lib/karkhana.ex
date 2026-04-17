defmodule Karkhana do
  @moduledoc """
  Entry point for the Karkhana orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Karkhana.Orchestrator.start_link(opts)
  end
end

defmodule Karkhana.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Karkhana.LogFile.configure()

    children = [
      {Phoenix.PubSub, name: Karkhana.PubSub},
      {Task.Supervisor, name: Karkhana.TaskSupervisor},
      Karkhana.Store,
      Karkhana.WorkflowStore,
      Karkhana.Orchestrator,
      Karkhana.HttpServer,
      Karkhana.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: Karkhana.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    Karkhana.StatusDashboard.render_offline_status()
    :ok
  end
end
