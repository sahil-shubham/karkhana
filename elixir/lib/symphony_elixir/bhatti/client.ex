defmodule SymphonyElixir.Bhatti.Client do
  @moduledoc """
  HTTP client for the bhatti sandbox API.
  """

  require Logger

  @timeout_ms 60_000

  @spec config() :: %{url: String.t(), api_key: String.t()}
  def config do
    settings = SymphonyElixir.Config.settings!()
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

    case :httpc.request(:post, request, [timeout: timeout_sec * 1000],
           sync: false, stream: :self, body_format: :binary) do
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

        {:post, body} ->
          {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}
      end

    http_method = if method == :delete, do: :delete, else: method

    case :httpc.request(http_method, http_req, [timeout: @timeout_ms], body_format: :binary) do
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
