defmodule Karkhana.Session do
  @moduledoc """
  A single agent session for one Linear issue.

  Each Session is a GenServer that owns the full lifecycle:
  create sandbox → run hooks → launch pi → consume events →
  run gates → transition Linear state → record run → exit.

  Events are broadcast to PubSub topic "session:<identifier>"
  for real-time dashboard updates. Session summary changes are
  broadcast to "sessions" for the session list.

  The Session checkpoints its state to SQLite (active_sessions table)
  so the Dispatcher can recover running sessions after a restart.
  """

  use GenServer
  require Logger

  alias Karkhana.{AgentRPC, Config, Gate, Linear.Issue, PromptBuilder, Protocol, Store, Tracker, Workspace}

  @pubsub Karkhana.PubSub
  @sessions_topic "sessions"
  @max_gate_retries 3

  # --- Public API ---

  @spec start_link({Issue.t(), keyword()}) :: GenServer.on_start()
  def start_link({issue, opts}) do
    name = {:via, Registry, {Karkhana.SessionRegistry, issue.identifier}}
    GenServer.start_link(__MODULE__, {issue, opts}, name: name)
  end

  @doc "Get current session status summary."
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc "Get last N events from the ring buffer."
  @spec events(GenServer.server(), pos_integer()) :: [map()]
  def events(server, limit \\ 50) do
    GenServer.call(server, {:events, limit})
  end

  @doc "Gracefully stop the session."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  @doc "Look up a session by issue identifier via Registry."
  @spec lookup(String.t()) :: GenServer.server() | nil
  def lookup(identifier) do
    case Registry.lookup(Karkhana.SessionRegistry, identifier) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "List all running session identifiers."
  @spec list_running() :: [String.t()]
  def list_running do
    Registry.select(Karkhana.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc false
  @spec status_for_test(%__MODULE__{}) :: map()
  def status_for_test(state), do: summary(state)

  # --- State ---

  defstruct [
    :issue,
    :sandbox_id,
    :sandbox_name,
    :mode,
    :mode_prompt,
    :session_id,
    :session_file,
    :started_at,
    :error,
    :gate_results,
    :gate_specs,
    :protocol_dir,
    :artifacts_config,
    :attempt,
    :config_hash,
    :agent,
    gate_retries: 0,
    tokens: %{input: 0, output: 0, total: 0, cache_read: 0, cache_write: 0},
    cost_usd: 0.0,
    events: :queue.new(),
    event_count: 0,
    turn_count: 0,
    status: :starting
  ]

  # --- Callbacks ---

  @impl true
  def init({issue, opts}) do
    state = %__MODULE__{
      issue: issue,
      attempt: Keyword.get(opts, :attempt, 0),
      started_at: DateTime.utc_now(),
      config_hash: Karkhana.WorkflowStore.config_hash()
    }

    # Check if this is a resume from a saved checkpoint
    case Keyword.get(opts, :resume) do
      %{} = saved ->
        state = %{
          state
          | sandbox_id: saved.sandbox_id,
            sandbox_name: saved[:sandbox_name],
            session_id: saved[:session_id],
            tokens: saved[:tokens] || state.tokens,
            cost_usd: saved[:cost_usd] || 0.0,
            mode: saved[:mode],
            status: :starting
        }

        Logger.info("Resuming session for #{issue.identifier}")
        broadcast_sessions({:session_started, summary(state)})
        # Resume from where we left off — re-enter the normal launch flow
        # which will start AgentRPC (the piped session in the sandbox may
        # still be running, but we create a fresh RPC connection).
        send(self(), :resolve_and_launch)
        {:ok, state}

      nil ->
        send(self(), :start_sandbox)
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:start_sandbox, state) do
    case Workspace.create_for_issue(state.issue) do
      {:ok, sandbox_id} ->
        sandbox_name = Workspace.sandbox_name_for_issue(state.issue)
        state = %{state | sandbox_id: sandbox_id, sandbox_name: sandbox_name}

        Logger.info("Session #{state.issue.identifier}: sandbox=#{sandbox_id}")
        send(self(), :run_hooks)
        {:noreply, state}

      {:error, reason} ->
        fail(state, "Sandbox creation failed: #{inspect(reason)}")
    end
  end

  def handle_info(:run_hooks, state) do
    case Workspace.run_before_run_hook(state.sandbox_id, state.issue) do
      :ok ->
        send(self(), :resolve_and_launch)
        {:noreply, state}

      {:error, reason} ->
        fail(state, "before_run hook failed: #{inspect(reason)}")
    end
  end

  def handle_info(:resolve_and_launch, state) do
    # Resolve mode AFTER hooks — before_run may git pull to update
    # .karkhana/modes/ in the sandbox.
    {mode, mode_prompt} = resolve_mode(state.sandbox_id, state.issue)
    {gate_specs, protocol_dir, artifacts_config} = load_gate_context(mode)

    state = %{
      state
      | mode: mode,
        mode_prompt: mode_prompt,
        gate_specs: gate_specs,
        protocol_dir: protocol_dir,
        artifacts_config: artifacts_config
    }

    Logger.info("Session #{state.issue.identifier}: mode=#{mode}")

    # Clean up stale documents from previous failed runs for this mode
    cleanup_stale_documents(state.issue, mode, gate_specs)

    send(self(), :launch_agent)
    {:noreply, state}
  end

  def handle_info(:launch_agent, state) do
    documents = fetch_issue_documents(state.issue)

    prompt =
      PromptBuilder.build_prompt(state.issue,
        mode: state.mode,
        mode_prompt: state.mode_prompt,
        attempt: state.attempt,
        gate_feedback: nil,
        documents: documents
      )

    settings = Config.settings!().claude
    me = self()

    case AgentRPC.start(state.sandbox_id,
           on_event: fn event -> send(me, {:rpc_event, event}) end,
           provider: settings.provider,
           model: settings.model
         ) do
      {:ok, agent} ->
        :ok = AgentRPC.prompt(agent, prompt)
        state = %{state | agent: agent, status: :running}
        Logger.info("Session #{state.issue.identifier}: agent launched via RPC")
        broadcast_sessions({:session_status, summary(state)})

        # Wait for completion asynchronously
        spawn_link(fn ->
          case AgentRPC.await_completion(agent) do
            {:ok, result} -> send(me, {:agent_completed, result})
            {:error, reason} -> send(me, {:agent_failed, reason})
          end
        end)

        {:noreply, state}

      {:error, reason} ->
        fail(state, "Agent RPC start failed: #{inspect(reason)}")
    end
  rescue
    e ->
      fail(state, "Agent crashed: #{Exception.message(e)}")
  end

  def handle_info({:rpc_event, event}, state) do
    state = process_rpc_event(state, event)
    {:noreply, state}
  end

  def handle_info({:agent_completed, result}, state) do
    # Try session_file from result first, then ask pi via RPC, then fallback to ls
    session_file =
      result[:session_file] ||
        fetch_session_file_via_rpc(state.agent) ||
        resolve_session_file(state.sandbox_id, state.session_id)

    state = %{state | session_file: session_file, status: :gates}
    Logger.info("Session #{state.issue.identifier}: agent completed, running gates")
    broadcast_sessions({:session_status, summary(state)})
    send(self(), :run_gates)
    {:noreply, state}
  end

  def handle_info({:agent_failed, reason}, state) do
    fail(state, "Agent failed: #{inspect(reason)}")
  end

  def handle_info(:run_gates, state) do
    gate_specs = state.gate_specs || []

    if gate_specs == [] do
      complete_success(state)
    else
      gate_context = %{
        sandbox_id: state.sandbox_id,
        issue_id: state.issue.id,
        issue_identifier: state.issue.identifier,
        mode: state.mode,
        attempt: state.attempt,
        protocol_dir: state.protocol_dir,
        artifacts: state.artifacts_config
      }

      case Gate.run_gates(gate_specs, gate_context) do
        {:all_passed, results} ->
          Logger.info("Session #{state.issue.identifier}: all gates passed")
          state = %{state | gate_results: results}
          complete_success(state)

        {:failed, results} ->
          feedback = Gate.failure_feedback(results)
          failed_names = Enum.map(feedback, & &1.gate) |> Enum.join(", ")
          state = %{state | gate_results: results}

          # Check if any failed gate wants retry_with_feedback
          retryable = has_retryable_gates?(results, state.gate_specs)

          if retryable and state.gate_retries < @max_gate_retries do
            Logger.info("Session #{state.issue.identifier}: gates failed (#{failed_names}), retrying with feedback (#{state.gate_retries + 1}/#{@max_gate_retries})")
            state = %{state | gate_retries: state.gate_retries + 1, status: :running}
            send(self(), {:retry_with_feedback, feedback})
            {:noreply, state}
          else
            Logger.warning("Session #{state.issue.identifier}: gates failed: #{failed_names}")
            fail(state, "Gates failed: #{failed_names}", :gate_failed)
          end
      end
    end
  end

  def handle_info({:retry_with_feedback, feedback}, state) do
    Logger.info("Session #{state.issue.identifier}: sending gate feedback via follow_up (retry #{state.gate_retries}/#{@max_gate_retries})")

    prompt = PromptBuilder.build_feedback_section(feedback, state.gate_retries)
    me = self()

    case AgentRPC.follow_up(state.agent, prompt) do
      :ok ->
        state = %{state | status: :running}
        broadcast_sessions({:session_status, summary(state)})

        spawn_link(fn ->
          case AgentRPC.await_completion(state.agent) do
            {:ok, result} -> send(me, {:agent_completed, result})
            {:error, reason} -> send(me, {:agent_failed, reason})
          end
        end)

        {:noreply, state}

      {:error, reason} ->
        fail(state, "Follow-up failed: #{inspect(reason)}")
    end
  rescue
    e ->
      fail(state, "Agent retry crashed: #{Exception.message(e)}")
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, summary(state), state}
  end

  def handle_call({:events, limit}, _from, state) do
    events =
      state.events
      |> :queue.to_list()
      |> Enum.take(-limit)

    {:reply, events, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Stop the RPC agent if still running
    if state.agent do
      try do
        AgentRPC.stop(state.agent)
      rescue
        _ -> :ok
      end
    end

    # Best-effort: run after_run hook if sandbox exists
    if state.sandbox_id do
      Workspace.run_after_run_hook(state.sandbox_id, state.issue)
    end

    :ok
  end

  # --- Event processing ---

  # --- RPC event processing ---

  defp process_rpc_event(state, %{"type" => "turn_start"}) do
    %{state | turn_count: state.turn_count + 1}
  end

  defp process_rpc_event(state, %{"type" => "turn_end"}) do
    # Broadcast updated summary after each turn so the dashboard
    # shows current token counts and turn progress.
    broadcast_sessions({:session_status, summary(state)})
    state
  end

  defp process_rpc_event(state, %{"type" => "message_update"} = event) do
    # Only extract token usage from streaming deltas — don't create
    # display events for every text_delta (hundreds per turn). The
    # message_end handler creates one display event per complete message.
    usage = extract_rpc_usage(event)
    {tokens, cost} = merge_usage(state, usage)
    %{state | tokens: tokens, cost_usd: cost}
  end

  defp process_rpc_event(state, %{"type" => "message_end"} = event) do
    # One display event per complete assistant message (not per streaming delta)
    text = get_in(event, ["message", "content"]) |> summarize_content_blocks()

    display_event = %{
      at: DateTime.utc_now(),
      type: :assistant,
      summary: text,
      raw: nil
    }

    broadcast_session(state.issue.identifier, {:session_event, display_event})

    %{state | events: :queue.in(display_event, state.events), event_count: state.event_count + 1}
  end

  defp process_rpc_event(state, %{"type" => "tool_execution_start"} = event) do
    tool = event["toolName"] || "tool"
    args = event["args"] || %{}
    detail = args["command"] || args["path"] || ""
    summary = "#{tool}: #{detail |> to_string() |> String.split("\n") |> hd() |> String.slice(0, 120)}"

    display_event = %{
      at: DateTime.utc_now(),
      type: :tool_use,
      summary: summary,
      raw: event
    }

    broadcast_session(state.issue.identifier, {:session_event, display_event})

    %{state | events: :queue.in(display_event, state.events), event_count: state.event_count + 1}
  end

  defp process_rpc_event(state, %{"type" => "auto_retry_start"} = event) do
    Logger.warning("Session #{state.issue.identifier}: auto-retry attempt #{event["attempt"]}: #{event["errorMessage"]}")
    state
  end

  defp process_rpc_event(state, _event), do: state

  defp extract_rpc_usage(%{"message" => %{"usage" => usage}}) when is_map(usage) do
    %{
      input_tokens: usage["input"] || 0,
      output_tokens: usage["output"] || 0,
      total_tokens: usage["totalTokens"] || 0,
      cache_read_tokens: usage["cacheRead"] || 0,
      cache_write_tokens: usage["cacheWrite"] || 0,
      cost_usd: get_in(usage, ["cost", "total"]) || 0.0
    }
  end

  defp extract_rpc_usage(_), do: nil

  defp merge_usage(state, nil), do: {state.tokens, state.cost_usd}

  defp merge_usage(state, usage) do
    tokens = %{
      input: max(state.tokens.input, usage.input_tokens),
      output: max(state.tokens.output, usage.output_tokens),
      total: max(state.tokens.total, usage.total_tokens),
      cache_read: max(state.tokens.cache_read, usage.cache_read_tokens),
      cache_write: max(state.tokens.cache_write, usage.cache_write_tokens)
    }

    cost = max(state.cost_usd, usage.cost_usd)
    {tokens, cost}
  end

  defp summarize_content_blocks(blocks) when is_list(blocks) do
    text_block = Enum.find(blocks, fn b -> is_map(b) and b["type"] == "text" end)

    cond do
      text_block ->
        (text_block["text"] || "") |> String.replace("\n", " ") |> String.trim() |> String.slice(0, 200)

      true ->
        ""
    end
  end

  defp summarize_content_blocks(_), do: ""

  # --- Completion ---

  defp complete_success(state) do
    state = %{state | status: :completed}
    Logger.info("Session #{state.issue.identifier}: completed successfully")

    # Lifecycle transition
    lifecycle_transition(state)

    # Record run
    record_run(state, :success)

    # Broadcast
    broadcast_sessions({:session_completed, summary(state)})
    broadcast_session(state.issue.identifier, {:session_completed, summary(state)})

    {:stop, :normal, state}
  end

  defp fail(state, error_message, outcome \\ :error) do
    state = %{state | status: :failed, error: error_message}
    Logger.warning("Session #{state.issue.identifier}: failed — #{error_message}")

    # Record run
    record_run(state, outcome, error_message)

    # Post error to Linear and move to fallback state
    post_error_comment(state, error_message)
    move_to_failure_state(state)

    # Broadcast
    broadcast_sessions({:session_failed, summary(state)})
    broadcast_session(state.issue.identifier, {:session_failed, summary(state)})

    {:stop, :normal, state}
  end

  defp lifecycle_transition(state) do
    lifecycle = Config.settings!().lifecycle
    issue_state = state.issue.state
    on_complete = Karkhana.Config.Schema.Lifecycle.on_complete_state(lifecycle, issue_state)

    if on_complete do
      Logger.info("Session #{state.issue.identifier}: transitioning #{issue_state} → #{on_complete}")

      case Tracker.update_issue_state(state.issue.id, on_complete) do
        :ok -> Logger.info("Session #{state.issue.identifier}: moved to #{on_complete}")
        {:error, reason} -> Logger.warning("Session #{state.issue.identifier}: transition failed: #{inspect(reason)}")
      end

      # Stop sandbox at human gates
      sandbox_action = Karkhana.Config.Schema.Lifecycle.sandbox_action(lifecycle, on_complete)

      if sandbox_action == "stop" and state.sandbox_id do
        Logger.info("Session #{state.issue.identifier}: stopping sandbox at human gate")

        case Karkhana.Bhatti.Client.stop_sandbox(state.sandbox_id) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Failed to stop sandbox: #{inspect(reason)}")
        end
      end
    end
  end

  defp record_run(state, outcome, error_message \\ nil) do
    run = %{
      issue_id: state.issue.id,
      issue_identifier: state.issue.identifier,
      mode: state.mode,
      config_hash: state.config_hash,
      attempt: state.attempt,
      sandbox_id: state.sandbox_id,
      sandbox_name: state.sandbox_name || "",
      session_id: state.session_id,
      session_file: state.session_file,
      tokens: %{
        input: state.tokens.input,
        output: state.tokens.output,
        cache_read: state.tokens.cache_read,
        cache_write: state.tokens.cache_write,
        total: state.tokens.total
      },
      cost_usd: state.cost_usd,
      duration_seconds: duration_seconds(state),
      outcome: outcome,
      error_message: error_message,
      gate: state.mode,
      gate_result: gate_result_summary(state.gate_results),
      gate_output: gate_output_summary(state.gate_results),
      labels: Issue.label_names(state.issue),
      started_at: state.started_at,
      ended_at: DateTime.utc_now()
    }

    case Store.insert_run(run) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to persist run: #{inspect(reason)}")
    end
  end

  defp move_to_failure_state(state) do
    # Use on_reject if configured, otherwise fall back to Backlog
    lifecycle = Config.settings!().lifecycle
    target = Karkhana.Config.Schema.Lifecycle.on_reject_state(lifecycle, state.issue.state) || "Backlog"

    case Tracker.update_issue_state(state.issue.id, target) do
      :ok -> Logger.info("Session #{state.issue.identifier}: moved to #{target}")
      {:error, reason} -> Logger.warning("Session #{state.issue.identifier}: failed to move to #{target}: #{inspect(reason)}")
    end
  rescue
    _ -> :ok
  end

  defp post_error_comment(state, error_message) do
    api_key = System.get_env("LINEAR_BOT_API_KEY") || System.get_env("LINEAR_API_KEY")

    if api_key && state.issue.id do
      body = """
      ⚠️ **Karkhana session failed**

      **Mode:** #{state.mode || "default"}
      **Error:** #{error_message}
      **Duration:** #{format_duration(duration_seconds(state))}
      **Attempt:** #{state.attempt}

      ---
      To retry → move to a dispatch state (Todo, Planning, Implementing)
      """

      case Karkhana.Linear.Client.post_comment(state.issue.id, body, api_key) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("Failed to post error comment: #{inspect(reason)}")
      end
    end
  end

  # --- Helpers ---

  defp resolve_mode(sandbox_id, issue) do
    lifecycle = Config.settings!().lifecycle
    lifecycle_mode = Karkhana.Config.Schema.Lifecycle.mode_for_state(lifecycle, issue.state)

    if lifecycle_mode do
      # Load prompt from .karkhana/modes/ inside the agent sandbox
      prompt_path = Karkhana.Config.Schema.Modes.prompt_path(Config.settings!().modes, lifecycle_mode)

      prompt_content =
        if prompt_path do
          remote_path = "/workspace/.karkhana/#{prompt_path}"
          Logger.info("Loading prompt from sandbox #{sandbox_id}: #{remote_path}")

          case Karkhana.Bhatti.Client.read_file(sandbox_id, remote_path) do
            {:ok, content} when is_binary(content) and content != "" ->
              content

            {:error, reason} ->
              Logger.warning("Failed to read prompt from sandbox: #{inspect(reason)}, falling back to local")
              read_prompt_local(prompt_path)
          end
        end

      {lifecycle_mode, prompt_content}
    else
      # Fallback: protocol-based resolution from sandbox
      case read_protocol_from_sandbox(sandbox_id) do
        {:ok, protocol} ->
          checker = fn cmd -> Karkhana.Bhatti.Client.exec_check(sandbox_id, cmd) end
          mode = Protocol.resolve_mode(protocol, issue, checker)
          {mode.name, mode.prompt_content}

        _ ->
          {"default", nil}
      end
    end
  end

  # Read prompt file from local .karkhana/ (fallback if sandbox read fails)
  defp read_prompt_local(prompt_path) do
    workspace = Config.settings!().workspace.root

    case Protocol.load(workspace) do
      {:ok, protocol} ->
        full_path = Path.join(protocol.dir, prompt_path)

        case File.read(full_path) do
          {:ok, content} -> content
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Load .karkhana/ protocol from inside the sandbox
  defp read_protocol_from_sandbox(_sandbox_id) do
    workspace = Config.settings!().workspace.root

    # Try local first (orchestrator may have a copy)
    case Protocol.load(workspace) do
      {:ok, _protocol} = ok -> ok
      _ -> {:error, :not_found}
    end
  end

  defp fetch_session_file_via_rpc(nil), do: nil

  defp fetch_session_file_via_rpc(agent) do
    case AgentRPC.get_state(agent) do
      {:ok, %{"sessionFile" => file}} when is_binary(file) and file != "" -> file
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Find the session JSONL file in the sandbox for this session ID.
  defp resolve_session_file(sandbox_id, session_id) when is_binary(sandbox_id) do
    cmd =
      if session_id do
        "ls /home/lohar/karkhana-sessions/*#{session_id}*.jsonl 2>/dev/null | tail -1"
      else
        "ls -t /home/lohar/karkhana-sessions/*.jsonl 2>/dev/null | head -1"
      end

    case Karkhana.Bhatti.Client.exec(sandbox_id, ["bash", "-c", cmd], timeout_sec: 5) do
      {:ok, %{"exit_code" => 0, "stdout" => path}} when byte_size(path) > 0 ->
        String.trim(path)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp resolve_session_file(_, _), do: nil

  # Clean up stale documents from previous failed runs.
  # Finds document_exists gates for this mode, extracts title patterns,
  # and deletes all matching documents on the issue.
  defp cleanup_stale_documents(%{id: issue_id} = _issue, _mode, gate_specs) when is_binary(issue_id) do
    # Find title patterns from document_exists gates
    title_patterns =
      (gate_specs || [])
      |> Enum.filter(fn spec -> spec["check"] == "document_exists" end)
      |> Enum.map(fn spec -> spec["title"] || spec["pattern"] end)
      |> Enum.reject(&is_nil/1)

    if title_patterns != [] do
      case Karkhana.Linear.Client.get_issue_documents(issue_id) do
        {:ok, docs} ->
          docs
          |> Enum.filter(fn doc ->
            title = String.downcase(doc["title"] || "")
            Enum.any?(title_patterns, fn pattern -> String.contains?(title, String.downcase(pattern)) end)
          end)
          |> Enum.each(fn doc ->
            Logger.info("Cleaning up stale document: #{doc["title"]} (#{doc["id"]})")
            Karkhana.Linear.Client.delete_document(doc["id"])
          end)

        {:error, reason} ->
          Logger.warning("Failed to clean up documents: #{inspect(reason)}")
      end
    end
  rescue
    _ -> :ok
  end

  defp cleanup_stale_documents(_, _, _), do: :ok

  # Fetch documents attached to the issue from Linear.
  # Returns a map of title => content for use in prompt templates.
  defp fetch_issue_documents(%{id: issue_id}) when is_binary(issue_id) do
    case Karkhana.Linear.Client.get_issue_documents(issue_id) do
      {:ok, docs} when is_list(docs) ->
        Map.new(docs, fn doc ->
          key = (doc["title"] || "untitled") |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
          {key, doc["content"] || ""}
        end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp fetch_issue_documents(_), do: %{}

  # Check if any failed gate has on_failure: "retry_with_feedback"
  defp has_retryable_gates?(results, gate_specs) do
    failed_names =
      results
      |> Enum.filter(fn {_name, status, _output} -> status == :fail end)
      |> Enum.map(fn {name, _, _} -> name end)
      |> MapSet.new()

    Enum.any?(gate_specs || [], fn spec ->
      name = spec["name"] || spec["check"] || ""
      MapSet.member?(failed_names, name) and spec["on_failure"] == "retry_with_feedback"
    end)
  end

  defp load_gate_context(mode) do
    settings = Config.settings!()
    gate_specs = Karkhana.Config.Schema.Modes.gates(settings.modes, mode)

    if gate_specs != [] do
      # Artifacts config lives in the raw WORKFLOW.md YAML, not in the Schema
      artifacts_config =
        case Karkhana.Workflow.current() do
          {:ok, %{config: config}} -> config["artifacts"] || %{}
          _ -> %{}
        end

      {gate_specs, nil, artifacts_config}
    else
      {[], nil, %{}}
    end
  end

  defp summary(state) do
    %{
      issue_id: state.issue.id,
      identifier: state.issue.identifier,
      title: state.issue.title,
      state: state.issue.state,
      mode: state.mode,
      status: state.status,
      sandbox_id: state.sandbox_id,
      session_id: state.session_id,
      tokens: state.tokens,
      cost_usd: state.cost_usd,
      event_count: state.event_count,
      turn_count: state.turn_count,
      attempt: state.attempt,
      started_at: state.started_at,
      error: state.error,
      gate_results: serialize_gate_results(state.gate_results)
    }
  end

  defp serialize_gate_results(nil), do: nil

  defp serialize_gate_results(results) when is_list(results) do
    Enum.map(results, fn
      {name, status, output} -> %{name: name, status: to_string(status), output: output}
      other -> other
    end)
  end

  defp duration_seconds(state) do
    DateTime.diff(DateTime.utc_now(), state.started_at, :second)
  end

  defp format_duration(seconds) when is_number(seconds) do
    minutes = div(trunc(seconds), 60)
    secs = rem(trunc(seconds), 60)
    if minutes > 0, do: "#{minutes}m #{secs}s", else: "#{secs}s"
  end

  defp format_duration(_), do: "n/a"

  defp gate_result_summary(nil), do: nil

  defp gate_result_summary(results) when is_list(results) do
    if Enum.any?(results, fn {_, s, _} -> s == :fail end), do: "fail", else: "pass"
  end

  defp gate_output_summary(nil), do: nil

  defp gate_output_summary(results) when is_list(results) do
    results
    |> Enum.map(fn {name, status, output} -> "#{name}: #{status} — #{output}" end)
    |> Enum.join("\n")
  end

  # --- PubSub ---

  defp broadcast_sessions(message) do
    Phoenix.PubSub.broadcast(@pubsub, @sessions_topic, message)
  rescue
    _ -> :ok
  end

  defp broadcast_session(identifier, message) do
    Phoenix.PubSub.broadcast(@pubsub, "session:#{identifier}", message)
  rescue
    _ -> :ok
  end
end
