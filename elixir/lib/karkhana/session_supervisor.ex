defmodule Karkhana.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for Session processes.

  Each active issue gets one Session child. The supervisor uses
  :one_for_one strategy — a session crash doesn't affect other
  sessions. Children are :temporary — they are not restarted
  on crash (the Dispatcher handles retry decisions).
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a new Session for an issue."
  @spec start_session(Karkhana.Linear.Issue.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(issue, opts \\ []) do
    start_session(__MODULE__, issue, opts)
  end

  @doc false
  @spec start_session(Supervisor.supervisor(), Karkhana.Linear.Issue.t(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_session(supervisor, issue, opts) do
    spec = %{
      id: issue.identifier,
      start: {Karkhana.Session, :start_link, [{issue, opts}]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(supervisor, spec)
  end

  @doc "Count currently running sessions."
  @spec count_sessions() :: non_neg_integer()
  def count_sessions do
    count_sessions(__MODULE__)
  end

  @doc false
  @spec count_sessions(Supervisor.supervisor()) :: non_neg_integer()
  def count_sessions(supervisor) do
    DynamicSupervisor.count_children(supervisor).active
  end
end
