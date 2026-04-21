defmodule Karkhana.Bhatti.WS do
  @moduledoc """
  WebSocket client for bhatti piped exec sessions.

  Uses Mint + MintWebSocket for a persistent WebSocket connection.
  Delivers received text frames to an `on_message` callback.
  """

  use GenServer
  require Logger

  @connect_timeout_ms 30_000

  defstruct [
    :conn,
    :websocket,
    :ref,
    :on_message,
    :on_close,
    :caller,
    buffer: "",
    status: :disconnected
  ]

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Connect to a bhatti sandbox's exec/ws endpoint.
  Sends the command spec as the first message.
  Returns `{:ok, session_id}` when the session info message arrives.
  """
  @spec connect(pid(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def connect(ws, sandbox_id, opts \\ []) do
    GenServer.call(ws, {:connect, sandbox_id, opts}, @connect_timeout_ms + 5_000)
  end

  @doc """
  Reattach to an existing piped session.
  """
  @spec reattach(pid(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def reattach(ws, sandbox_id, session_id) do
    GenServer.call(ws, {:reattach, sandbox_id, session_id}, @connect_timeout_ms + 5_000)
  end

  @doc """
  Send a text frame over the WebSocket.
  Appends a newline if not already present — pi RPC reads JSONL.
  """
  @spec send_text(pid(), String.t()) :: :ok | {:error, term()}
  def send_text(ws, text) do
    text = if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
    GenServer.call(ws, {:send, text})
  end

  @doc "Close the connection."
  @spec close(pid()) :: :ok
  def close(ws) do
    GenServer.stop(ws, :normal)
  catch
    :exit, _ -> :ok
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      on_message: Keyword.fetch!(opts, :on_message),
      on_close: Keyword.get(opts, :on_close, fn _reason -> :ok end)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:connect, sandbox_id, opts}, from, state) do
    cmd = Keyword.fetch!(opts, :cmd)
    env = Keyword.get(opts, :env, %{})
    max_idle_sec = Keyword.get(opts, :max_idle_sec, 3600)

    path = "/sandboxes/#{sandbox_id}/exec/ws"

    case do_ws_connect(path, state) do
      {:ok, conn, websocket, ref} ->
        # Send command spec
        spec = Jason.encode!(%{cmd: cmd, env: env, max_idle_sec: max_idle_sec})
        {:ok, conn, websocket} = send_ws_text(conn, websocket, ref, spec)

        state = %{state | conn: conn, websocket: websocket, ref: ref, caller: from, status: :connecting}
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reattach, sandbox_id, session_id}, from, state) do
    path = "/sandboxes/#{sandbox_id}/exec/ws?session=#{session_id}"

    case do_ws_connect(path, state) do
      {:ok, conn, websocket, ref} ->
        state = %{state | conn: conn, websocket: websocket, ref: ref, caller: from, status: :connecting}
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send, text}, _from, %{status: :connected} = state) do
    case send_ws_text(state.conn, state.websocket, state.ref, text) do
      {:ok, conn, websocket} ->
        {:reply, :ok, %{state | conn: conn, websocket: websocket}}

      {:error, conn, websocket, reason} ->
        {:reply, {:error, reason}, %{state | conn: conn, websocket: websocket}}
    end
  end

  def handle_call({:send, _text}, _from, state) do
    {:reply, {:error, :disconnected}, state}
  end

  @impl true
  def handle_info(message, state) when state.conn != nil do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, [{:data, ref, data}]} when ref == state.ref ->
        case Mint.WebSocket.decode(state.websocket, data) do
          {:ok, websocket, frames} ->
            state = %{state | conn: conn, websocket: websocket}
            state = process_frames(frames, state)
            {:noreply, state}

          {:error, websocket, reason} ->
            handle_ws_error(%{state | conn: conn, websocket: websocket}, reason)
        end

      {:ok, conn, _other} ->
        {:noreply, %{state | conn: conn}}

      {:error, conn, reason, _responses} ->
        handle_ws_error(%{state | conn: conn}, reason)

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn} = _state) when conn != nil do
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Private ---

  defp do_ws_connect(path, _state) do
    %{url: base_url, api_key: api_key} = Karkhana.Bhatti.Client.config()
    uri = URI.parse(base_url)

    scheme = if uri.scheme == "https", do: :https, else: :http
    host = uri.host
    port = uri.port || if(scheme == :https, do: 443, else: 80)

    ws_scheme = if scheme == :https, do: :wss, else: :ws

    # Force HTTP/1.1 — Cloudflare doesn't support HTTP/2 extended CONNECT
    # for WebSocket upgrade (returns enable_connect_protocol: false).
    connect_opts =
      if scheme == :https do
        [protocols: [:http1], transport_opts: [verify: :verify_none]]
      else
        [protocols: [:http1]]
      end

    with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port, connect_opts),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, [
             {"authorization", "Bearer #{api_key}"}
           ]) do
      # Accumulate upgrade response frames. HTTP/1.1 sends :status, :headers,
      # :done as separate responses (possibly across multiple messages).
      collect_upgrade_response(conn, ref, nil, nil)
    end
  end

  defp collect_upgrade_response(conn, ref, status, headers) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {conn, status, headers, done} =
              Enum.reduce(responses, {conn, status, headers, false}, fn
                {:status, ^ref, s}, {c, _, h, d} -> {c, s, h, d}
                {:headers, ^ref, h}, {c, s, _, d} -> {c, s, h, d}
                {:done, ^ref}, {c, s, h, _} -> {c, s, h, true}
                _, acc -> acc
              end)

            if done do
              if status == 101 do
                case Mint.WebSocket.new(conn, ref, status, headers) do
                  {:ok, conn, websocket} ->
                    {:ok, conn, websocket, ref}

                  {:error, conn, reason} ->
                    Mint.HTTP.close(conn)
                    {:error, reason}
                end
              else
                Mint.HTTP.close(conn)
                {:error, {:upgrade_failed, status}}
              end
            else
              # Not done yet — keep receiving
              collect_upgrade_response(conn, ref, status, headers)
            end

          {:error, conn, reason, _} ->
            Mint.HTTP.close(conn)
            {:error, reason}

          :unknown ->
            collect_upgrade_response(conn, ref, status, headers)
        end
    after
      @connect_timeout_ms ->
        Mint.HTTP.close(conn)
        {:error, :connect_timeout}
    end
  end

  defp send_ws_text(conn, websocket, ref, text) do
    send_ws_frame(conn, websocket, ref, {:text, text})
  end

  defp send_ws_frame(conn, websocket, ref, frame) do
    case Mint.WebSocket.encode(websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn} -> {:ok, conn, websocket}
          {:error, conn, reason} -> {:error, conn, websocket, reason}
        end

      {:error, websocket, reason} ->
        {:error, conn, websocket, reason}
    end
  end

  defp process_frames([], state), do: state

  defp process_frames([{:text, data} | rest], state) do
    # Each WS text frame may be:
    # 1. A complete JSON object (session info, exit message from bhatti server)
    # 2. Raw stdout bytes from pi (may contain multiple newline-delimited JSON lines,
    #    or partial lines split across frames)
    # Strategy: append to buffer, extract all complete lines, process each.
    # A "line" is any \n-terminated segment. Unterminated remainder stays buffered.
    # Also try the whole buffer as a single JSON object for frames without newlines
    # (like the session info message from bhatti).
    buffer = state.buffer <> data
    {lines, remainder} = split_lines(buffer)

    state = %{state | buffer: remainder}

    # Process complete lines
    state =
      Enum.reduce(lines, state, fn line, acc ->
        handle_text_line(line, acc)
      end)

    # If no lines were extracted but we have a non-empty remainder that
    # looks like complete JSON, try it directly. This handles WS frames
    # that are complete JSON objects without a trailing newline (e.g.
    # the session info message from bhatti's handleSandboxExecWS).
    state =
      if lines == [] and remainder != "" do
        case Jason.decode(remainder) do
          {:ok, _} ->
            state = handle_text_line(remainder, %{state | buffer: ""})
            state

          {:error, _} ->
            state
        end
      else
        state
      end

    process_frames(rest, state)
  end

  defp process_frames([{:close, _code, _reason} | _rest], state) do
    state.on_close.({:ws_close, :normal})
    %{state | status: :disconnected}
  end

  defp process_frames([{:ping, data} | rest], state) do
    # Reply with pong
    case send_ws_frame(state.conn, state.websocket, state.ref, {:pong, data}) do
      {:ok, conn, websocket} ->
        process_frames(rest, %{state | conn: conn, websocket: websocket})

      {:error, conn, websocket, _reason} ->
        process_frames(rest, %{state | conn: conn, websocket: websocket})
    end
  end

  defp process_frames([_frame | rest], state), do: process_frames(rest, state)

  defp handle_text_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"type" => "session", "session_id" => sid}} ->
        # This is the session info message — reply to the waiting caller
        if state.caller do
          GenServer.reply(state.caller, {:ok, sid})
        end

        %{state | caller: nil, status: :connected}

      {:ok, %{"error" => _msg}} when state.caller != nil ->
        GenServer.reply(state.caller, {:error, line})
        %{state | caller: nil, status: :disconnected}

      _ ->
        # Regular message — deliver to callback
        state.on_message.(line)
        state
    end
  end

  defp handle_ws_error(state, reason) do
    Logger.warning("WS error: #{inspect(reason)}")

    if state.caller do
      GenServer.reply(state.caller, {:error, reason})
    end

    state.on_close.({:ws_error, reason})
    {:noreply, %{state | status: :disconnected, caller: nil}}
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n") do
      [single] ->
        {[], single}

      parts ->
        {complete, [remainder]} = Enum.split(parts, -1)
        {Enum.reject(complete, &(&1 == "")), remainder}
    end
  end
end
