defmodule Karkhana.SessionReader do
  @moduledoc """
  Reads pi session JSONL files and parses them into a summarized
  conversation for display in the dashboard.

  Sessions are stored as JSONL files in the orchestrator's session
  archive directory. Each line is a JSON object with a `type` field.
  We extract: user messages, assistant text, tool calls (summarized),
  and model/thinking metadata.
  """

  @session_archive_dir "/home/lohar/karkhana/sessions"

  @type turn :: %{
          role: String.t(),
          text: String.t(),
          tools: [String.t()],
          timestamp: String.t() | nil
        }

  @type session_summary :: %{
          file: String.t(),
          sandbox: String.t(),
          turns: [turn()],
          models: [String.t()],
          session_id: String.t() | nil,
          started_at: String.t() | nil
        }

  @doc """
  List all sandbox names that have archived sessions.
  """
  @spec list_sandboxes() :: [String.t()]
  def list_sandboxes do
    case File.ls(@session_archive_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(@session_archive_dir, &1)))
        |> Enum.sort(:desc)

      {:error, _} ->
        []
    end
  end

  @doc """
  List session files for a given sandbox.
  """
  @spec list_sessions(String.t()) :: [String.t()]
  def list_sessions(sandbox_name) do
    dir = Path.join(@session_archive_dir, sandbox_name)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort(:desc)

      {:error, _} ->
        []
    end
  end

  @doc """
  Read and summarize a session JSONL file into a conversation.
  Returns {:ok, summary} or {:error, reason}.
  """
  @spec read_session(String.t(), String.t()) :: {:ok, session_summary()} | {:error, term()}
  def read_session(sandbox_name, filename) do
    path = Path.join([@session_archive_dir, sandbox_name, filename])

    case File.read(path) do
      {:ok, content} ->
        {:ok, parse_session(content, sandbox_name, filename)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Read a session directly from a sandbox (for active/non-archived sessions).
  Uses bhatti exec to cat the file.
  """
  @spec read_live_session(String.t(), String.t()) :: {:ok, session_summary()} | {:error, term()}
  def read_live_session(sandbox_id, session_path) do
    case Karkhana.Bhatti.Client.exec(sandbox_id, ["cat", session_path], timeout_sec: 10) do
      {:ok, %{"exit_code" => 0, "stdout" => content}} ->
        {:ok, parse_session(content, "live-#{sandbox_id}", Path.basename(session_path))}

      {:ok, %{"exit_code" => code}} ->
        {:error, {:read_failed, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Parsing ---

  defp parse_session(content, sandbox_name, filename) do
    lines = String.split(content, "\n", trim: true)

    {session_info, turns, models} =
      Enum.reduce(lines, {%{}, [], []}, fn line, {info, turns, models} ->
        case Jason.decode(line) do
          {:ok, entry} -> process_entry(entry, info, turns, models)
          _ -> {info, turns, models}
        end
      end)

    %{
      file: filename,
      sandbox: sandbox_name,
      turns: Enum.reverse(turns),
      models: Enum.uniq(models),
      session_id: session_info["id"],
      started_at: session_info["timestamp"]
    }
  end

  defp process_entry(%{"type" => "session"} = entry, _info, turns, models) do
    {entry, turns, models}
  end

  defp process_entry(%{"type" => "model_change"} = entry, info, turns, models) do
    {info, turns, [entry["modelId"] | models]}
  end

  defp process_entry(%{"type" => "message"} = entry, info, turns, models) do
    msg = entry["message"] || %{}
    role = msg["role"]
    content = msg["content"] || []
    timestamp = entry["timestamp"]

    texts = extract_texts(content)
    tool_calls = extract_tool_calls(content)

    turn =
      cond do
        role == "user" && texts != "" ->
          %{role: "user", text: texts, tools: [], timestamp: timestamp}

        role == "assistant" && (texts != "" || tool_calls != []) ->
          %{role: "assistant", text: texts, tools: tool_calls, timestamp: timestamp}

        true ->
          nil
      end

    if turn do
      {info, [turn | turns], models}
    else
      {info, turns, models}
    end
  end

  defp process_entry(_, info, turns, models), do: {info, turns, models}

  defp extract_texts(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} -> [text]
      text when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp extract_texts(_), do: ""

  defp extract_tool_calls(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "toolCall", "name" => name} = call ->
        args = call["arguments"] || %{}
        summary = summarize_tool_call(name, args)
        [summary]

      _ ->
        []
    end)
  end

  defp extract_tool_calls(_), do: []

  defp summarize_tool_call("bash", %{"command" => cmd}) do
    "bash: #{String.slice(cmd, 0, 80)}"
  end

  defp summarize_tool_call("read", %{"path" => path}) do
    "read: #{path}"
  end

  defp summarize_tool_call("edit", %{"path" => path}) do
    "edit: #{path}"
  end

  defp summarize_tool_call("write", %{"path" => path}) do
    "write: #{path}"
  end

  defp summarize_tool_call(name, _args), do: name
end
