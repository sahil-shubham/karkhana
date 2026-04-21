defmodule Karkhana.Linear.WorkflowSync do
  @moduledoc """
  Syncs workflow states declared in lifecycle config to a Linear team.

  On orchestrator init (or workflow reload), this module:
  1. Resolves the team ID from the project slug
  2. Fetches existing workflow states for the team
  3. Creates any states declared in lifecycle.states that don't exist
  4. Caches the state name → ID mapping for fast transitions

  ## State ID cache

  After sync, `state_id!/1` returns the Linear state UUID for a given
  state name. This eliminates the per-transition GraphQL lookup that
  `Linear.Adapter.update_issue_state` currently does.

  ## Idempotency

  Sync is idempotent: existing states (matched by name) are skipped.
  States are never deleted or modified — only created.
  """

  use GenServer
  require Logger

  alias Karkhana.Config
  alias Karkhana.Linear.Client

  @team_from_project_query """
  query KarkhanaTeamFromProject($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}) {
      nodes {
        teams {
          nodes { id name }
        }
      }
    }
  }
  """

  @team_states_query """
  query KarkhanaTeamStates($teamId: String!) {
    team(id: $teamId) {
      states {
        nodes { id name type color position }
      }
    }
  }
  """

  @create_state_mutation """
  mutation KarkhanaCreateWorkflowState($input: WorkflowStateCreateInput!) {
    workflowStateCreate(input: $input) {
      success
      workflowState { id name type }
    }
  }
  """

  @update_state_mutation """
  mutation KarkhanaUpdateWorkflowState($id: String!, $input: WorkflowStateUpdateInput!) {
    workflowStateUpdate(id: $id, input: $input) {
      success
    }
  }
  """

  # --- GenServer API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get the cached Linear state ID for a state name. Raises if not found."
  @spec state_id!(String.t()) :: String.t()
  def state_id!(state_name) do
    state_id!(__MODULE__, state_name)
  end

  @doc false
  @spec state_id!(GenServer.server(), String.t()) :: String.t()
  def state_id!(server, state_name) do
    case GenServer.call(server, {:state_id, state_name}) do
      {:ok, id} -> id
      :not_found -> raise "WorkflowSync: no cached state ID for '#{state_name}'"
    end
  end

  @doc "Get the cached state ID, returning nil if not found."
  @spec state_id(String.t()) :: String.t() | nil
  def state_id(state_name) do
    state_id(__MODULE__, state_name)
  end

  @doc false
  @spec state_id(GenServer.server(), String.t()) :: String.t() | nil
  def state_id(server, state_name) do
    case GenServer.call(server, {:state_id, state_name}) do
      {:ok, id} -> id
      :not_found -> nil
    end
  end

  @doc "Get the full state_ids cache (name → ID map)."
  @spec state_ids() :: %{String.t() => String.t()}
  def state_ids do
    state_ids(__MODULE__)
  end

  @doc false
  @spec state_ids(GenServer.server()) :: %{String.t() => String.t()}
  def state_ids(server) do
    GenServer.call(server, :state_ids)
  end

  @doc "Trigger a re-sync (called on workflow reload)."
  @spec sync() :: :ok | {:error, term()}
  def sync do
    sync(__MODULE__)
  end

  @doc false
  @spec sync(GenServer.server()) :: :ok | {:error, term()}
  def sync(server) do
    GenServer.call(server, :sync, 30_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    state = %{state_ids: %{}, team_id: nil, synced: false}

    # Run initial sync after a short delay (let config load)
    Process.send_after(self(), :initial_sync, 100)

    {:ok, state}
  end

  @impl true
  def handle_call({:state_id, state_name}, _from, state) do
    case Map.get(state.state_ids, state_name) do
      nil -> {:reply, :not_found, state}
      id -> {:reply, {:ok, id}, state}
    end
  end

  def handle_call(:state_ids, _from, state) do
    {:reply, state.state_ids, state}
  end

  def handle_call(:sync, _from, state) do
    case do_sync() do
      {:ok, result} ->
        {:reply, :ok, %{state | state_ids: result.state_ids, team_id: result.team_id, synced: true}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:initial_sync, state) do
    case do_sync() do
      {:ok, result} ->
        {:noreply, %{state | state_ids: result.state_ids, team_id: result.team_id, synced: true}}

      {:error, reason} ->
        Logger.warning("WorkflowSync initial sync failed: #{inspect(reason)}; will retry on next sync call")
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Sync logic ---

  @spec do_sync() :: {:ok, %{state_ids: map(), team_id: String.t(), created: [String.t()], existing: [String.t()]}} | {:error, term()}
  defp do_sync do
    settings = Config.settings!()
    lifecycle = settings.lifecycle

    if lifecycle.states == %{} or not lifecycle.auto_sync do
      Logger.info("WorkflowSync: no lifecycle states configured or auto_sync disabled; skipping")
      {:ok, %{state_ids: %{}, team_id: nil, created: [], existing: []}}
    else
      with {:ok, team_id} <- resolve_team_id(settings),
           {:ok, existing_states} <- fetch_team_states(team_id),
           {:ok, result} <- sync_states(team_id, lifecycle, existing_states) do
        reorder_states(lifecycle, result.state_ids, existing_states)
        {:ok, result}
      end
    end
  end

  defp resolve_team_id(settings) do
    project_slug = settings.tracker.project_slug

    if is_nil(project_slug) do
      {:error, :missing_project_slug}
    else
      case Client.graphql(@team_from_project_query, %{projectSlug: project_slug}) do
        {:ok, %{"data" => %{"projects" => %{"nodes" => [project | _]}}}} ->
          case get_in(project, ["teams", "nodes"]) do
            [%{"id" => team_id, "name" => team_name} | _] ->
              Logger.info("WorkflowSync: resolved team '#{team_name}' (#{team_id}) from project slug '#{project_slug}'")
              {:ok, team_id}

            _ ->
              {:error, :no_team_for_project}
          end

        {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}} ->
          {:error, {:project_not_found, project_slug}}

        {:error, reason} ->
          {:error, {:team_resolution_failed, reason}}
      end
    end
  end

  defp fetch_team_states(team_id) do
    case Client.graphql(@team_states_query, %{teamId: team_id}) do
      {:ok, %{"data" => %{"team" => %{"states" => %{"nodes" => states}}}}} ->
        {:ok, states}

      {:error, reason} ->
        {:error, {:fetch_states_failed, reason}}
    end
  end

  defp sync_states(team_id, lifecycle, existing_states) do
    existing_by_name = Map.new(existing_states, fn s -> {s["name"], s} end)

    results =
      lifecycle.states
      |> Enum.map(fn {name, config} ->
        case Map.get(existing_by_name, name) do
          nil ->
            create_state(team_id, name, config)

          existing ->
            Logger.debug("WorkflowSync: state '#{name}' already exists (#{existing["id"]})")
            {:existing, name, existing["id"]}
        end
      end)

    created = for {:created, name, _id} <- results, do: name
    existing = for {:existing, name, _id} <- results, do: name
    errors = for {:error, name, _reason} <- results, do: name

    state_ids =
      results
      |> Enum.flat_map(fn
        {:created, name, id} -> [{name, id}]
        {:existing, name, id} -> [{name, id}]
        _ -> []
      end)
      |> Map.new()

    # Also include existing states that aren't in lifecycle config
    # (so we can transition to them even if not managed by karkhana)
    all_state_ids =
      existing_states
      |> Enum.reduce(state_ids, fn %{"name" => name, "id" => id}, acc ->
        Map.put_new(acc, name, id)
      end)

    if created != [] do
      Logger.info("WorkflowSync: created #{length(created)} states: #{Enum.join(created, ", ")}")
    end

    if errors != [] do
      Logger.warning("WorkflowSync: failed to create #{length(errors)} states: #{Enum.join(errors, ", ")}")
    end

    {:ok, %{state_ids: all_state_ids, team_id: team_id, created: created, existing: existing}}
  end

  defp create_state(team_id, name, config) do
    linear_type = config["linear_type"] || "started"
    color = config["color"] || "#95a2b3"
    description = config["description"] || "Managed by karkhana"

    input = %{
      name: name,
      type: linear_type,
      color: color,
      teamId: team_id,
      description: description
    }

    case Client.graphql(@create_state_mutation, %{input: input}) do
      {:ok, %{"data" => %{"workflowStateCreate" => %{"success" => true, "workflowState" => ws}}}} ->
        Logger.info("WorkflowSync: created state '#{name}' (#{linear_type}) id=#{ws["id"]}")
        {:created, name, ws["id"]}

      {:ok, response} ->
        Logger.warning("WorkflowSync: failed to create state '#{name}': #{inspect(response)}")
        {:error, name, response}

      {:error, reason} ->
        Logger.warning("WorkflowSync: failed to create state '#{name}': #{inspect(reason)}")
        {:error, name, reason}
    end
  end

  # Reorder states in Linear to match the lifecycle config order.
  # The lifecycle states map is unordered, but we define a logical order:
  # idle states first, then dispatch states in pipeline order (following
  # on_complete chains), then human gates, then terminals.
  defp reorder_states(lifecycle, state_ids, existing_states) do
    existing_positions = Map.new(existing_states, fn s -> {s["name"], s["position"]} end)

    # Build ordered list by following the on_complete chain from each entry point
    ordered = build_state_order(lifecycle)

    # Check if positions already match
    needs_update =
      ordered
      |> Enum.with_index()
      |> Enum.any?(fn {name, idx} ->
        current_pos = existing_positions[name]
        current_pos != nil and current_pos != idx
      end)

    if needs_update do
      ordered
      |> Enum.with_index()
      |> Enum.each(fn {name, position} ->
        case Map.get(state_ids, name) do
          nil ->
            :ok

          id ->
            case Client.graphql(@update_state_mutation, %{id: id, input: %{position: position}}) do
              {:ok, %{"data" => %{"workflowStateUpdate" => %{"success" => true}}}} ->
                :ok

              {:ok, resp} ->
                Logger.debug("WorkflowSync: failed to reorder '#{name}': #{inspect(resp)}")

              {:error, reason} ->
                Logger.debug("WorkflowSync: failed to reorder '#{name}': #{inspect(reason)}")
            end
        end
      end)

      Logger.info("WorkflowSync: reordered states: #{Enum.join(ordered, " → ")}")
    end
  end

  # Build a logical ordering of states using topological sort on on_complete edges.
  # A state X that has on_complete: Y means X comes before Y in the pipeline.
  defp build_state_order(lifecycle) do
    states = lifecycle.states
    names = Map.keys(states)

    # Build a dependency graph: if X.on_complete = Y, then X must come before Y.
    # We sort so that states earlier in the pipeline get lower positions.
    edges =
      for {name, config} <- states,
          target = config["on_complete"],
          target != nil,
          Map.has_key?(states, target),
          do: {name, target}

    # Topological sort via Kahn's algorithm
    in_degree = Map.new(names, fn n -> {n, 0} end)

    in_degree =
      Enum.reduce(edges, in_degree, fn {_from, to}, acc ->
        Map.update(acc, to, 1, &(&1 + 1))
      end)

    adjacency =
      Enum.reduce(edges, Map.new(names, fn n -> {n, []} end), fn {from, to}, acc ->
        Map.update(acc, from, [to], &[to | &1])
      end)

    # Start with nodes that have no incoming edges (entry points)
    queue =
      in_degree
      |> Enum.filter(fn {_, d} -> d == 0 end)
      |> Enum.map(fn {n, _} -> n end)
      # Stable sort: idle first, then unstarted, then started, then terminals
      |> Enum.sort_by(fn name ->
        config = states[name]

        type_order =
          case config["type"] do
            "idle" -> 0
            "dispatch" -> 1
            "human_gate" -> 2
            "terminal" -> 3
            _ -> 4
          end

        linear_order =
          case config["linear_type"] do
            "backlog" -> 0
            "unstarted" -> 1
            "started" -> 2
            "completed" -> 3
            "canceled" -> 4
            _ -> 5
          end

        {type_order, linear_order, name}
      end)

    # Partition: process non-terminals first, terminals at the end
    {non_terminal, terminal} =
      Enum.split_with(queue, fn name ->
        states[name]["type"] not in ["terminal"]
      end)

    topo_sort(non_terminal, adjacency, in_degree, []) ++ terminal
  end

  defp topo_sort([], _adj, _in_deg, result), do: Enum.reverse(result)

  defp topo_sort([node | rest], adjacency, in_degree, result) do
    neighbors = Map.get(adjacency, node, [])

    {new_queue, new_in_degree} =
      Enum.reduce(neighbors, {rest, in_degree}, fn neighbor, {q, deg} ->
        new_deg = Map.update!(deg, neighbor, &(&1 - 1))

        if new_deg[neighbor] == 0 do
          {q ++ [neighbor], new_deg}
        else
          {q, new_deg}
        end
      end)

    topo_sort(new_queue, adjacency, new_in_degree, [node | result])
  end
end
