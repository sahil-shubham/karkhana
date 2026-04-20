defmodule Karkhana.AgentRPC do
  @moduledoc """
  Manages a persistent pi RPC connection through bhatti's piped session.

  Replaces `Karkhana.Claude.CLI`. Provides:
  - `start/2` — launch pi in RPC mode, connect via WebSocket
  - `prompt/2` — send a task prompt, stream events
  - `follow_up/2` — send gate feedback in the same session
  - `steer/2` — inject mid-turn instruction
  - `await_completion/2` — block until agent_end
  - `get_state/1` — session file, streaming status
  - `get_session_stats/1` — token counts, cost
  - `stop/1` — shutdown pi
  """

  use GenServer
  require Logger

  alias Karkhana.Bhatti.WS

  @session_dir "/home/lohar/karkhana-sessions"
  @default_idle_sec 3600
  @command_timeout 30_000

  defstruct [
    :sandbox_id,
    :ws,
    :session_id,
    :on_event,
    completion_waiters: [],
    pending_responses: %{},
    request_counter: 0,
    session_file: nil,
    is_streaming: false,
    status: :idle
  ]

  # --- Public API ---

  @spec start(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(sandbox_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {sandbox_id, opts})
  end

  @spec prompt(pid(), String.t()) :: :ok | {:error, term()}
  def prompt(agent, prompt_text) do
    GenServer.call(agent, {:prompt, prompt_text})
  end

  @spec follow_up(pid(), String.t()) :: :ok | {:error, term()}
  def follow_up(agent, message) do
    GenServer.call(agent, {:follow_up, message})
  end

  @spec steer(pid(), String.t()) :: :ok | {:error, term()}
  def steer(agent, message) do
    GenServer.call(agent, {:steer, message})
  end

  @spec await_completion(pid(), timeout()) :: {:ok, map()} | {:error, term()}
  def await_completion(agent, timeout \\ :infinity) do
    GenServer.call(agent, :await_completion, timeout)
  end

  @spec get_state(pid()) :: {:ok, map()} | {:error, term()}
  def get_state(agent) do
    GenServer.call(agent, :get_state, @command_timeout)
  end

  @spec get_session_stats(pid()) :: {:ok, map()} | {:error, term()}
  def get_session_stats(agent) do
    GenServer.call(agent, :get_session_stats, @command_timeout)
  end

  @spec abort(pid()) :: :ok | {:error, term()}
  def abort(agent) do
    GenServer.call(agent, :abort)
  end

  @spec stop(pid()) :: :ok
  def stop(agent) do
    GenServer.stop(agent, :normal)
  catch
    :exit, _ -> :ok
  end

  # --- Callbacks ---

  @impl true
  def init({sandbox_id, opts}) do
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)

    cmd = build_pi_command(provider, model)

    me = self()

    {:ok, ws} =
      WS.start_link(
        on_message: fn msg -> send(me, {:ws_message, msg}) end,
        on_close: fn reason -> send(me, {:ws_closed, reason}) end
      )

    case WS.connect(ws, sandbox_id,
           cmd: cmd,
           env: build_env(opts),
           max_idle_sec: Keyword.get(opts, :max_idle_sec, @default_idle_sec)
         ) do
      {:ok, session_id} ->
        Logger.info("AgentRPC: connected to sandbox #{sandbox_id}, session=#{session_id}")

        # Configure pi for production use
        send_rpc_command(ws, "set_auto_compaction", %{enabled: true})
        send_rpc_command(ws, "set_auto_retry", %{enabled: true})

        state = %__MODULE__{
          sandbox_id: sandbox_id,
          ws: ws,
          session_id: session_id,
          on_event: on_event
        }

        {:ok, state}

      {:error, reason} ->
        WS.close(ws)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:prompt, text}, _from, state) do
    {id, state} = next_request_id(state)
    cmd = Jason.encode!(%{type: "prompt", message: text, id: id})

    case WS.send_text(state.ws, cmd) do
      :ok ->
        {:reply, :ok, %{state | is_streaming: true, status: :running}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:follow_up, text}, _from, state) do
    {id, state} = next_request_id(state)
    cmd = Jason.encode!(%{type: "follow_up", message: text, id: id})

    case WS.send_text(state.ws, cmd) do
      :ok ->
        {:reply, :ok, %{state | is_streaming: true, status: :running}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:steer, text}, _from, state) do
    cmd = Jason.encode!(%{type: "steer", message: text})
    result = WS.send_text(state.ws, cmd)
    {:reply, result, state}
  end

  def handle_call(:await_completion, from, state) do
    if state.status != :running do
      {:reply, {:ok, %{session_id: state.session_id, session_file: state.session_file}}, state}
    else
      {:noreply, %{state | completion_waiters: [from | state.completion_waiters]}}
    end
  end

  def handle_call(:get_state, from, state) do
    {id, state} = next_request_id(state)
    cmd = Jason.encode!(%{type: "get_state", id: id})

    case WS.send_text(state.ws, cmd) do
      :ok ->
        {:noreply, %{state | pending_responses: Map.put(state.pending_responses, id, from)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_session_stats, from, state) do
    {id, state} = next_request_id(state)
    cmd = Jason.encode!(%{type: "get_session_stats", id: id})

    case WS.send_text(state.ws, cmd) do
      :ok ->
        {:noreply, %{state | pending_responses: Map.put(state.pending_responses, id, from)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:abort, _from, state) do
    cmd = Jason.encode!(%{type: "abort"})
    result = WS.send_text(state.ws, cmd)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:ws_message, data}, state) do
    case Jason.decode(data) do
      {:ok, event} ->
        state = process_rpc_event(event, state)
        {:noreply, state}

      {:error, _} ->
        Logger.debug("AgentRPC: skipping non-JSON: #{String.slice(data, 0, 100)}")
        {:noreply, state}
    end
  end

  def handle_info({:ws_closed, reason}, state) do
    Logger.warning("AgentRPC: WebSocket closed: #{inspect(reason)}")

    # Fail pending request-response calls immediately (get_state, get_session_stats)
    for {_id, from} <- state.pending_responses do
      GenServer.reply(from, {:error, {:ws_closed, reason}})
    end

    state = %{state | pending_responses: %{}}

    if state.status == :running do
      # Agent may still be working inside the sandbox — attempt reconnect
      send(self(), {:reconnect, 1})
      {:noreply, %{state | status: :reconnecting}}
    else
      # Agent was idle — notify completion waiters and give up
      for waiter <- state.completion_waiters do
        GenServer.reply(waiter, {:error, {:ws_closed, reason}})
      end

      {:noreply, %{state | status: :disconnected, completion_waiters: []}}
    end
  end

  @max_reconnect_attempts 5

  def handle_info({:reconnect, attempt}, state) when attempt <= @max_reconnect_attempts do
    backoff_ms = min(1000 * Integer.pow(2, attempt - 1), 30_000)
    Process.sleep(backoff_ms)

    me = self()

    {:ok, ws} =
      WS.start_link(
        on_message: fn msg -> send(me, {:ws_message, msg}) end,
        on_close: fn reason -> send(me, {:ws_closed, reason}) end
      )

    case WS.reattach(ws, state.sandbox_id, state.session_id) do
      {:ok, _session_id} ->
        Logger.info("AgentRPC: reconnected (attempt #{attempt})")
        # Close the old WS if it's still alive
        if state.ws, do: WS.close(state.ws)

        # After reconnect, scrollback replay may contain agent_end.
        # Those arrive as regular {:ws_message, ...} and process_rpc_event
        # handles them. If agent finished during disconnect, we'll get
        # agent_end in the replay and notify completion waiters.
        #
        # If scrollback overflowed and agent_end was lost, poll get_state
        # after a short delay to detect idle status.
        Process.send_after(self(), :check_idle_after_reconnect, 2_000)

        {:noreply, %{state | ws: ws, status: :running}}

      {:error, reason} ->
        Logger.warning("AgentRPC: reconnect failed (attempt #{attempt}): #{inspect(reason)}")
        WS.close(ws)
        send(self(), {:reconnect, attempt + 1})
        {:noreply, state}
    end
  end

  def handle_info({:reconnect, _attempt}, state) do
    Logger.error("AgentRPC: reconnect failed after #{@max_reconnect_attempts} attempts")

    for waiter <- state.completion_waiters do
      GenServer.reply(waiter, {:error, :reconnect_exhausted})
    end

    {:noreply, %{state | status: :disconnected, completion_waiters: []}}
  end

  def handle_info(:check_idle_after_reconnect, %{status: :running} = state) do
    # If we reconnected but haven't received agent_end from scrollback,
    # check if pi is actually idle. This handles the case where agent_end
    # was lost due to scrollback overflow.
    {id, state} = next_request_id(state)
    cmd = Jason.encode!(%{type: "get_state", id: id})

    case WS.send_text(state.ws, cmd) do
      :ok ->
        state = %{state | pending_responses: Map.put(state.pending_responses, id, {:internal, :check_idle})}
        {:noreply, state}

      {:error, _} ->
        {:noreply, state}
    end
  end

  def handle_info(:check_idle_after_reconnect, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.ws, do: WS.close(state.ws)
    :ok
  end

  # --- Event Processing ---

  defp process_rpc_event(%{"type" => "response"} = event, state) do
    id = event["id"]

    case Map.pop(state.pending_responses, id) do
      {nil, _} ->
        state.on_event.(event)
        state

      {{:internal, :check_idle}, pending} ->
        # Internal get_state check after reconnect
        state = %{state | pending_responses: pending}

        if event["success"] && get_in(event, ["data", "isStreaming"]) == false &&
             state.status == :running do
          # Pi is idle but we never got agent_end (scrollback overflow).
          # Treat this as completion.
          Logger.info("AgentRPC: detected idle after reconnect (missed agent_end)")

          result = %{
            session_id: state.session_id,
            session_file: get_in(event, ["data", "sessionFile"]),
            messages: nil
          }

          for waiter <- state.completion_waiters do
            GenServer.reply(waiter, {:ok, result})
          end

          %{state | is_streaming: false, status: :idle, completion_waiters: []}
        else
          state
        end

      {from, pending} ->
        if event["success"] do
          GenServer.reply(from, {:ok, event["data"]})
        else
          GenServer.reply(from, {:error, event["error"]})
        end

        %{state | pending_responses: pending}
    end
  end

  defp process_rpc_event(%{"type" => "agent_end"} = event, state) do
    state.on_event.(event)

    result = %{
      session_id: state.session_id,
      session_file: state.session_file,
      messages: event["messages"]
    }

    for waiter <- state.completion_waiters do
      GenServer.reply(waiter, {:ok, result})
    end

    %{state | is_streaming: false, status: :idle, completion_waiters: []}
  end

  defp process_rpc_event(%{"type" => "agent_start"} = event, state) do
    state.on_event.(event)
    %{state | is_streaming: true, status: :running}
  end

  defp process_rpc_event(event, state) do
    state.on_event.(event)
    state
  end

  # --- Helpers ---

  defp build_pi_command(provider, model) do
    settings = Karkhana.Config.settings!().claude
    command = settings.command || "pi"

    args = [command, "--mode", "rpc", "--session-dir", @session_dir]
    args = if provider, do: args ++ ["--provider", provider], else: args
    args = if model, do: args ++ ["--model", model], else: args
    args
  end

  defp build_env(opts) do
    Keyword.get(opts, :env, %{})
  end

  defp send_rpc_command(ws, type, params) do
    cmd = Map.merge(%{type: type}, params) |> Jason.encode!()
    WS.send_text(ws, cmd)
  end

  defp next_request_id(state) do
    counter = state.request_counter + 1
    id = "krk-#{counter}"
    {id, %{state | request_counter: counter}}
  end
end
