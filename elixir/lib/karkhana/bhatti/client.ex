defmodule Karkhana.Bhatti.Client do
  @moduledoc """
  HTTP client for the bhatti sandbox API.
  """

  require Logger

  @timeout_ms 60_000

  @spec config() :: %{url: String.t(), api_key: String.t()}
  def config do
    settings = Karkhana.Config.settings!()
    %{url: settings.bhatti.url, api_key: settings.bhatti.api_key}
  end

  @spec create_sandbox(map()) :: {:ok, map()} | {:error, term()}
  def create_sandbox(spec) do
    post("/sandboxes", spec)
  end

  @spec destroy_sandbox(String.t()) :: :ok | {:error, term()}
  def destroy_sandbox(sandbox_id) do
    case request(:delete, "/sandboxes/#{sandbox_id}") do
      {:ok, %{status: status}} when status in [200, 204] -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checkpoint a running sandbox. Snapshots VM state to disk without
  interrupting the running process. Used before gate checks so we
  can resume from the checkpoint if a gate fails.
  """
  @spec checkpoint(String.t()) :: {:ok, map()} | {:error, term()}
  def checkpoint(sandbox_id) do
    post("/sandboxes/#{sandbox_id}/checkpoint", %{})
  end

  @doc """
  Stop (pause) a sandbox. Snapshots the VM to disk and frees host
  resources. Resume with start/1. Used at human gates to free RAM
  while waiting for review.
  """
  @spec stop_sandbox(String.t()) :: :ok | {:error, term()}
  def stop_sandbox(sandbox_id) do
    case request(:post, "/sandboxes/#{sandbox_id}/stop") do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Start (resume) a stopped sandbox. Resumes from snapshot in ~3ms.
  Used when a human approves work at a gate and karkhana dispatches
  the next mode.
  """
  @spec start_sandbox(String.t()) :: :ok | {:error, term()}
  def start_sandbox(sandbox_id) do
    case request(:post, "/sandboxes/#{sandbox_id}/start") do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generate a one-time shell token for browser-based terminal access.
  Returns %{"token" => ..., "url" => ...}. Used in the dashboard
  so reviewers can inspect sandbox state during human gates.
  """
  @spec create_shell_token(String.t()) :: {:ok, map()} | {:error, term()}
  def create_shell_token(sandbox_id) do
    post("/sandboxes/#{sandbox_id}/shell-token", %{})
  end

  @doc """
  Publish a port inside the sandbox as a public URL.
  Used by QA agents to expose running services for review.
  """
  @spec publish(String.t(), integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish(sandbox_id, port, opts \\ []) do
    body = %{"port" => port}
    body = if opts[:alias], do: Map.put(body, "alias", opts[:alias]), else: body
    post("/sandboxes/#{sandbox_id}/publish", body)
  end

  @doc """
  Update sandbox attributes (e.g. keep_hot toggle).
  """
  @spec update_sandbox(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_sandbox(sandbox_id, attrs) when is_map(attrs) do
    case request(:patch, "/sandboxes/#{sandbox_id}", attrs) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_sandboxes() :: {:ok, [map()]} | {:error, term()}
  def list_sandboxes do
    get("/sandboxes")
  end

  @spec exec(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def exec(sandbox_id, cmd, opts \\ []) do
    timeout_sec = Keyword.get(opts, :timeout_sec, 3600)

    post("/sandboxes/#{sandbox_id}/exec", %{
      "cmd" => cmd,
      "timeout_sec" => timeout_sec
    })
  end

  @doc """
  Run a command and return true if exit code is 0, false otherwise.
  Used for artifact existence checks in mode resolution.
  """
  @spec exec_check(String.t(), String.t(), keyword()) :: boolean()
  def exec_check(sandbox_id, cmd, opts \\ []) do
    timeout_sec = Keyword.get(opts, :timeout_sec, 10)

    case exec(sandbox_id, ["bash", "-c", cmd], timeout_sec: timeout_sec) do
      {:ok, %{"exit_code" => 0}} -> true
      _ -> false
    end
  end

  @spec exec_detached(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def exec_detached(sandbox_id, cmd, opts \\ []) do
    timeout_sec = Keyword.get(opts, :timeout_sec, 3600)

    post("/sandboxes/#{sandbox_id}/exec", %{
      "cmd" => cmd,
      "timeout_sec" => timeout_sec,
      "detach" => true
    })
  end

  @spec exec_stream(String.t(), [String.t()], (String.t() -> any()), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def exec_stream(sandbox_id, cmd, on_stdout_line, opts \\ []) do
    timeout_sec = Keyword.get(opts, :timeout_sec, 3600)
    %{url: base_url, api_key: api_key} = config()
    url = base_url <> "/sandboxes/#{sandbox_id}/exec"

    body =
      Jason.encode!(%{
        "cmd" => cmd,
        "timeout_sec" => timeout_sec
      })

    # Use :httpc streaming mode to avoid Cloudflare 524 timeouts.
    # The {sync, false} option makes :httpc return chunks as messages.
    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"application/x-ndjson"},
      {~c"authorization", ~c"Bearer #{api_key}"}
    ]

    :inets.start()
    :ssl.start()

    request = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, request, [timeout: timeout_sec * 1000], sync: false, stream: :self, body_format: :binary) do
      {:ok, request_id} ->
        stream_receive_loop(request_id, on_stdout_line, "", nil, timeout_sec * 1000)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_receive_loop(request_id, on_stdout_line, buffer, exit_code, timeout_ms) do
    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        stream_receive_loop(request_id, on_stdout_line, buffer, exit_code, timeout_ms)

      {:http, {^request_id, :stream, chunk}} when is_binary(chunk) ->
        {new_buffer, new_exit} = process_chunk(buffer <> chunk, on_stdout_line, exit_code)
        stream_receive_loop(request_id, on_stdout_line, new_buffer, new_exit, timeout_ms)

      {:http, {^request_id, :stream, chunk}} when is_list(chunk) ->
        {new_buffer, new_exit} = process_chunk(buffer <> IO.iodata_to_binary(chunk), on_stdout_line, exit_code)
        stream_receive_loop(request_id, on_stdout_line, new_buffer, new_exit, timeout_ms)

      {:http, {^request_id, :stream_end, _headers}} ->
        # Process any remaining buffer
        {_, final_exit} = process_chunk(buffer, on_stdout_line, exit_code)
        {:ok, final_exit || 0}

      {:http, {^request_id, {{_, status, _}, _headers, resp_body}}} ->
        # Non-streaming response (error case)
        {:error, {:http_error, status, resp_body}}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, reason}
    after
      timeout_ms ->
        :httpc.cancel_request(request_id)
        {:error, :timeout}
    end
  end

  defp process_chunk(data, on_stdout_line, exit_code) do
    # Split on newlines, keep incomplete last line as buffer
    lines = String.split(data, "\n")
    {complete_lines, [remainder]} = Enum.split(lines, -1)

    new_exit =
      Enum.reduce(complete_lines, exit_code, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{"type" => "stdout", "data" => stdout_data}} ->
            on_stdout_line.(stdout_data)
            acc

          {:ok, %{"type" => "exit", "exit_code" => code}} ->
            code

          _ ->
            acc
        end
      end)

    {remainder, new_exit}
  end

  @spec read_file(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(sandbox_id, path) do
    %{url: base_url, api_key: api_key} = config()
    url = base_url <> "/sandboxes/#{sandbox_id}/files?path=#{URI.encode(path)}"

    headers = [
      {~c"authorization", ~c"Bearer #{api_key}"}
    ]

    :inets.start()
    :ssl.start()

    request = {String.to_charlist(url), headers}

    case :httpc.request(:get, request, [timeout: @timeout_ms], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _, body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_file(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(sandbox_id, path, content) do
    %{url: base_url, api_key: api_key} = config()
    url = base_url <> "/sandboxes/#{sandbox_id}/files?path=#{URI.encode(path)}"

    headers = [
      {~c"content-type", ~c"application/octet-stream"},
      {~c"content-length", String.to_charlist(Integer.to_string(byte_size(content)))},
      {~c"authorization", ~c"Bearer #{api_key}"}
    ]

    :inets.start()
    :ssl.start()

    request = {String.to_charlist(url), headers, ~c"application/octet-stream", content}

    case :httpc.request(:put, request, [timeout: @timeout_ms], body_format: :binary) do
      {:ok, {{_, status, _}, _, _}} when status in [200, 201, 204] -> :ok
      {:ok, {{_, status, _}, _, body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- private ---

  defp get(path) do
    case request(:get, path) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post(path, body) do
    case request(:post, path, body) do
      {:ok, %{status: status, body: resp}} when status in [200, 201] -> {:ok, resp}
      {:ok, %{status: status, body: resp}} -> {:error, {:http_error, status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(method, path, body \\ nil) do
    %{url: base_url, api_key: api_key} = config()
    url = base_url <> path

    headers = [
      {~c"authorization", ~c"Bearer #{api_key}"},
      {~c"content-type", ~c"application/json"}
    ]

    :inets.start()
    :ssl.start()

    http_req =
      case {method, body} do
        {:get, _} ->
          {String.to_charlist(url), headers}

        {:delete, _} ->
          {String.to_charlist(url), headers}

        {_, body} when body != nil ->
          {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}

        _ ->
          {String.to_charlist(url), headers}
      end

    case :httpc.request(method, http_req, [timeout: @timeout_ms], body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        decoded =
          case Jason.decode(resp_body) do
            {:ok, parsed} -> parsed
            _ -> resp_body
          end

        {:ok, %{status: status, body: decoded}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
