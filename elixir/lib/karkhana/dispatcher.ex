defmodule Karkhana.Dispatcher do
  @moduledoc """
  Thin polling loop that watches Linear and starts Session processes.

  The Dispatcher does three things:
  1. Poll Linear for issues in dispatch states
  2. Start Session processes for new issues
  3. Monitor sessions and handle exits

  All session state (tokens, cost, events) lives in Session processes,
  not here. The Dispatcher is just the matchmaker.
  """

  use GenServer
  require Logger

  alias Karkhana.{Config, Linear.Issue, SessionSupervisor, Tracker}

  defstruct [
    :poll_interval_ms,
    :max_concurrent,
    :max_retries,
    dispatched: %{},
    # issue IDs that failed — skip on next poll
    failed: MapSet.new()
  ]

  @type dispatch_entry :: %{pid: pid(), ref: reference(), attempt: non_neg_integer(), identifier: String.t()}

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get the current dispatch state (for observability)."
  @spec info() :: map()
  def info, do: info(__MODULE__)

  @doc false
  @spec info(GenServer.server()) :: map()
  def info(server), do: GenServer.call(server, :info)

  @doc "Trigger an immediate poll cycle."
  @spec refresh() :: :ok
  def refresh, do: refresh(__MODULE__)

  @doc false
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server) do
    send(server, :poll)
    :ok
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    config = Config.settings!()

    state = %__MODULE__{
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, config.polling.interval_ms),
      max_concurrent: Keyword.get(opts, :max_concurrent, config.agent.max_concurrent_agents),
      max_retries: Keyword.get(opts, :max_retries, 0)
    }

    # Recover any sessions that were running before a restart
    send(self(), :recover)

    # Start the poll loop
    schedule_poll(state.poll_interval_ms)

    Logger.info("Dispatcher started: poll=#{state.poll_interval_ms}ms max_concurrent=#{state.max_concurrent} max_retries=#{state.max_retries}")
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    schedule_poll(state.poll_interval_ms)
    state = poll_and_dispatch(state)
    {:noreply, state}
  end

  def handle_info(:recover, state) do
    state = recover_sessions(state)
    {:noreply, state}
  end

  def handle_info({:retry, issue_id, attempt}, state) do
    # Re-fetch the issue from Linear to get current state
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue]} ->
        if dispatchable?(issue) and not dispatched?(state, issue.id) do
          state = start_session(state, issue, attempt)
          {:noreply, state}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_by_ref(state, ref) do
      {issue_id, entry} ->
        state = %{state | dispatched: Map.delete(state.dispatched, issue_id)}

        state =
          case reason do
            :normal ->
              Logger.info("Session completed for #{entry.identifier}")
              state

            _ ->
              Logger.warning("Session exited for #{entry.identifier}: #{inspect(reason)}")

              if entry.attempt < state.max_retries do
                Logger.info("Scheduling retry #{entry.attempt + 1}/#{state.max_retries} for #{entry.identifier}")
                Process.send_after(self(), {:retry, issue_id, entry.attempt + 1}, 10_000)
                state
              else
                %{state | failed: MapSet.put(state.failed, issue_id)}
              end
          end

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:tracker_event, _event}, state) do
    # Webhook event — trigger an immediate poll
    send(self(), :poll)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      dispatched:
        Map.new(state.dispatched, fn {id, entry} ->
          {id, %{identifier: entry.identifier, attempt: entry.attempt, pid: entry.pid}}
        end),
      dispatched_count: map_size(state.dispatched),
      max_concurrent: state.max_concurrent,
      max_retries: state.max_retries,
      poll_interval_ms: state.poll_interval_ms
    }

    {:reply, info, state}
  end

  # --- Polling ---

  defp poll_and_dispatch(state) do
    case fetch_dispatch_candidates() do
      {:ok, issues} ->
        issues
        |> Enum.filter(&should_dispatch?(&1, state))
        |> Enum.reduce(state, fn issue, acc ->
          start_session(acc, issue, 0)
        end)

      {:error, reason} ->
        Logger.warning("Dispatcher poll failed: #{inspect(reason)}")
        state
    end
  end

  defp fetch_dispatch_candidates do
    case Config.validate!() do
      :ok -> Tracker.fetch_candidate_issues()
      {:error, reason} -> {:error, reason}
    end
  end

  defp should_dispatch?(issue, state) do
    dispatchable?(issue) and
      not dispatched?(state, issue.id) and
      not failed?(state, issue.id) and
      available_slots(state) > 0
  end

  defp dispatchable?(%Issue{id: id, state: issue_state} = issue)
       when is_binary(id) and is_binary(issue_state) do
    lifecycle = Config.settings!().lifecycle

    case Karkhana.Config.Schema.Lifecycle.state_config(lifecycle, issue_state) do
      %{"type" => "dispatch"} ->
        # force evaluation to verify issue is valid
        Issue.label_names(issue)
        true

      _ ->
        false
    end
  end

  defp dispatchable?(_), do: false

  defp dispatched?(state, issue_id), do: Map.has_key?(state.dispatched, issue_id)
  defp failed?(state, issue_id), do: MapSet.member?(state.failed, issue_id)
  defp available_slots(state), do: max(state.max_concurrent - map_size(state.dispatched), 0)

  # --- Session management ---

  defp start_session(state, issue, attempt) do
    lifecycle = Config.settings!().lifecycle
    lifecycle_mode = Karkhana.Config.Schema.Lifecycle.mode_for_state(lifecycle, issue.state)

    opts = [attempt: attempt]
    opts = if lifecycle_mode, do: Keyword.put(opts, :lifecycle_mode, lifecycle_mode), else: opts

    case SessionSupervisor.start_session(issue, opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatched #{issue.identifier} (#{issue.state}) mode=#{lifecycle_mode} attempt=#{attempt}")

        entry = %{pid: pid, ref: ref, attempt: attempt, identifier: issue.identifier}
        %{state | dispatched: Map.put(state.dispatched, issue.id, entry)}

      {:error, {:already_started, _pid}} ->
        Logger.debug("Session already running for #{issue.identifier}")
        state

      {:error, reason} ->
        Logger.error("Failed to start session for #{issue.identifier}: #{inspect(reason)}")
        state
    end
  end

  # --- Recovery ---

  defp recover_sessions(state) do
    case Karkhana.Store.list_active_sessions() do
      {:ok, sessions} when sessions != [] ->
        Logger.info("Recovering #{length(sessions)} sessions from checkpoint")

        Enum.reduce(sessions, state, fn saved, acc ->
          recover_one(acc, saved)
        end)

      {:ok, []} ->
        state

      _ ->
        Logger.debug("No active sessions to recover")
        state
    end
  rescue
    # Store might not have the active_sessions table yet
    _ -> state
  end

  defp recover_one(state, saved) do
    sandbox_id = saved.sandbox_id

    # Check if sandbox still exists and agent is running
    case check_sandbox(sandbox_id) do
      :running ->
        Logger.info("Recovering session #{saved.issue_identifier} (sandbox #{sandbox_id})")

        issue = deserialize_issue(saved)

        resume_opts = %{
          sandbox_id: saved.sandbox_id,
          sandbox_name: saved.sandbox_name,
          output_file: saved.output_file,
          lines_seen: saved.lines_seen,
          mode: saved.mode,
          tokens: %{
            input: saved.tokens_input || 0,
            output: saved.tokens_output || 0,
            total: saved.tokens_total || 0,
            cache_read: saved.tokens_cache_read || 0,
            cache_write: 0
          },
          cost_usd: saved.cost_usd || 0.0
        }

        opts = [attempt: saved.attempt || 0, resume: resume_opts]

        case SessionSupervisor.start_session(issue, opts) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            entry = %{pid: pid, ref: ref, attempt: saved.attempt || 0, identifier: saved.issue_identifier}
            %{state | dispatched: Map.put(state.dispatched, saved.issue_id, entry)}

          {:error, reason} ->
            Logger.warning("Failed to recover session #{saved.issue_identifier}: #{inspect(reason)}")
            Karkhana.Store.delete_active_session(saved.issue_id)
            state
        end

      :gone ->
        Logger.warning("Sandbox gone for #{saved.issue_identifier}, recording lost session")
        record_lost_session(saved)
        Karkhana.Store.delete_active_session(saved.issue_id)
        state
    end
  end

  defp check_sandbox(sandbox_id) do
    case Karkhana.Bhatti.Client.exec(sandbox_id, ["echo", "alive"], timeout_sec: 5) do
      {:ok, %{"exit_code" => 0}} -> :running
      _ -> :gone
    end
  rescue
    _ -> :gone
  end

  defp deserialize_issue(saved) do
    case Jason.decode(saved.issue_json || "{}") do
      {:ok, data} ->
        %Issue{
          id: saved.issue_id,
          identifier: saved.issue_identifier,
          title: data["title"],
          description: data["description"],
          state: data["state"],
          url: data["url"],
          labels: data["labels"] || [],
          assigned_to_worker: true
        }

      _ ->
        %Issue{
          id: saved.issue_id,
          identifier: saved.issue_identifier,
          title: "",
          state: "",
          labels: [],
          assigned_to_worker: true
        }
    end
  end

  defp record_lost_session(saved) do
    run = %{
      issue_id: saved.issue_id,
      issue_identifier: saved.issue_identifier,
      mode: saved.mode,
      config_hash: nil,
      attempt: saved.attempt || 0,
      sandbox_id: saved.sandbox_id,
      sandbox_name: saved.sandbox_name || "",
      session_id: saved.session_id,
      tokens: %{
        input: saved.tokens_input || 0,
        output: saved.tokens_output || 0,
        cache_read: saved.tokens_cache_read || 0,
        cache_write: 0,
        total: saved.tokens_total || 0
      },
      cost_usd: saved.cost_usd || 0.0,
      duration_seconds: 0,
      outcome: :error,
      error_message: "Lost session (karkhana restarted, sandbox gone)",
      labels: [],
      started_at: saved.started_at || DateTime.utc_now(),
      ended_at: DateTime.utc_now()
    }

    Karkhana.Store.insert_run(run)
  end

  # --- Helpers ---

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp find_by_ref(state, ref) do
    Enum.find_value(state.dispatched, fn {issue_id, entry} ->
      if entry.ref == ref, do: {issue_id, entry}
    end)
  end
end
