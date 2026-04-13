defmodule SymphonyElixir.Claude.CLI do
  @moduledoc """
  Runs Claude Code CLI inside bhatti sandboxes.

  Approach: fire-and-forget exec that writes output to a file,
  then poll the file for results. This avoids Cloudflare tunnel
  timeouts on long-running HTTP requests.
  """

  require Logger

  alias SymphonyElixir.Bhatti.Client, as: Bhatti
  alias SymphonyElixir.Claude.StreamParser
  alias SymphonyElixir.Config

  @poll_interval_ms 3_000
  @output_file "/tmp/karkhana-claude.jsonl"
  @done_marker "__KARKHANA_DONE__"

  @type run_result :: %{
          session_id: String.t() | nil,
          exit_code: integer(),
          usage: map() | nil
        }

  @spec run(String.t(), String.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(prompt, sandbox_id, opts \\ []) do
    args = build_first_turn_args(prompt)
    execute(args, sandbox_id, opts)
  end

  @spec resume(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, run_result()} | {:error, term()}
  def resume(session_id, prompt, sandbox_id, opts \\ []) do
    args = build_resume_args(session_id, prompt)
    execute(args, sandbox_id, opts)
  end

  @prompt_file "/tmp/karkhana-prompt.txt"

  defp execute(args, sandbox_id, opts) do
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, Config.settings!().claude.turn_timeout_ms)

    # Extract prompt from args and write to a file inside the sandbox.
    # The prompt contains markdown, URLs, parens, quotes — anything that
    # would break shell escaping. Reading from file avoids all of that.
    {prompt, other_args} = extract_prompt(args)

    with :ok <- Bhatti.write_file(sandbox_id, @prompt_file, prompt) do
      command = Config.settings!().claude.command

      # other_args are simple flags (--verbose, --output-format, etc) — no
      # special characters, no escaping needed. They go inside the bash -c
      # single-quoted string so must NOT be individually single-quoted.
      plain_args = Enum.join(other_args, " ")

      # Use setsid to fully detach the process from the bhatti exec session.
      # nohup alone isn't enough — bhatti's agent waits for stdout to close,
      # and backgrounded processes can still hold pty references.
      # setsid creates a new session, fully detaching from the controlling terminal.
      launch_cmd =
        "rm -f #{@output_file} && " <>
        "setsid bash -c '#{command} -p \"$(cat #{@prompt_file})\" #{plain_args} " <>
        "< /dev/null > #{@output_file} 2>/dev/null; " <>
        "echo #{@done_marker}:$? >> #{@output_file}' " <>
        "< /dev/null > /dev/null 2>&1 &"

      Logger.info("Claude launch cmd (#{String.length(launch_cmd)} chars): #{String.slice(launch_cmd, 0, 120)}...")

      case Bhatti.exec(sandbox_id, ["bash", "-c", launch_cmd], timeout_sec: 30) do
        {:ok, _} ->
          Logger.info("Claude launched in sandbox #{sandbox_id}, polling output...")
          poll_output(sandbox_id, on_event, turn_timeout_ms)

        {:error, reason} ->
          {:error, {:launch_failed, reason}}
      end
    end
  end

  defp extract_prompt(args) do
    extract_prompt(args, [])
  end

  defp extract_prompt(["-p", prompt | rest], acc), do: {prompt, Enum.reverse(acc) ++ rest}
  defp extract_prompt([arg | rest], acc), do: extract_prompt(rest, [arg | acc])
  defp extract_prompt([], acc), do: {"", Enum.reverse(acc)}

  defp poll_output(sandbox_id, on_event, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_loop(sandbox_id, on_event, deadline, 0, %{session_id: nil, usage: nil})
  end

  defp poll_loop(sandbox_id, on_event, deadline, lines_seen, state) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      # Kill claude process
      Bhatti.exec(sandbox_id, ["bash", "-c", "pkill -f 'claude.*print' 2>/dev/null"], timeout_sec: 5)
      {:error, :turn_timeout}
    else
      Process.sleep(@poll_interval_ms)

      # Read new lines from the output file
      skip_cmd = if lines_seen > 0, do: "tail -n +#{lines_seen + 1}", else: "cat"
      read_cmd = "#{skip_cmd} #{@output_file} 2>/dev/null"

      case Bhatti.exec(sandbox_id, ["bash", "-c", read_cmd], timeout_sec: 15) do
        {:ok, %{"exit_code" => 0, "stdout" => stdout}} ->
          lines = String.split(stdout, "\n", trim: true)
          {new_state, done_exit} = process_lines(lines, on_event, state)
          new_lines_seen = lines_seen + length(lines)

          case done_exit do
            nil ->
              poll_loop(sandbox_id, on_event, deadline, new_lines_seen, new_state)

            0 ->
              {:ok, %{session_id: new_state.session_id, exit_code: 0, usage: new_state.usage}}

            code ->
              {:error, {:subprocess_exit, code}}
          end

        {:ok, _} ->
          # File doesn't exist yet or read error — keep polling
          poll_loop(sandbox_id, on_event, deadline, lines_seen, state)

        {:error, reason} ->
          Logger.warning("Poll read failed: #{inspect(reason)}, retrying...")
          poll_loop(sandbox_id, on_event, deadline, lines_seen, state)
      end
    end
  end

  defp process_lines(lines, on_event, state) do
    Enum.reduce(lines, {state, nil}, fn line, {acc_state, acc_exit} ->
      cond do
        String.starts_with?(line, @done_marker) ->
          code = line |> String.split(":") |> List.last() |> String.trim() |> String.to_integer()
          {acc_state, code}

        true ->
          case StreamParser.parse_line(line) do
            {:ok, event} ->
              session_id = StreamParser.extract_session_id(event) || acc_state.session_id
              usage = StreamParser.extract_usage(event) || acc_state.usage
              on_event.(event)
              {%{acc_state | session_id: session_id, usage: usage}, acc_exit}

            {:error, _} ->
              {acc_state, acc_exit}
          end
      end
    end)
  end

  defp build_first_turn_args(prompt) do
    settings = Config.settings!().claude
    command = settings.command || "pi"

    case detect_agent(command) do
      :pi -> build_pi_args(prompt, settings)
      :claude -> build_claude_args(prompt, settings)
    end
  end

  defp build_resume_args(_session_id, prompt) do
    # pi doesn't support --resume; each turn is independent.
    # Claude supports --resume but we use pi now.
    # For both: just send the prompt as a new invocation.
    build_first_turn_args(prompt)
  end

  defp build_pi_args(prompt, settings) do
    base = [
      "-p", prompt,
      "--mode", "json",
      "--no-session"
    ]

    base
    |> maybe_add_flag(settings.dangerously_skip_permissions, "--dangerously-skip-permissions")
    |> maybe_add_option(settings.model, "--model")
  end

  defp build_claude_args(prompt, settings) do
    base = [
      "-p", prompt,
      "--verbose",
      "--output-format", "stream-json",
      "--max-turns", to_string(settings.max_turns)
    ]

    base
    |> maybe_add_flag(settings.dangerously_skip_permissions, "--dangerously-skip-permissions")
    |> maybe_add_option(settings.model, "--model")
    |> maybe_add_allowed_tools(settings.allowed_tools)
  end

  defp detect_agent(command) do
    if String.contains?(command, "pi"), do: :pi, else: :claude
  end

  defp maybe_add_flag(args, true, flag), do: args ++ [flag]
  defp maybe_add_flag(args, _, _), do: args

  defp maybe_add_option(args, nil, _), do: args
  defp maybe_add_option(args, value, opt), do: args ++ [opt, value]

  defp maybe_add_allowed_tools(args, nil), do: args
  defp maybe_add_allowed_tools(args, []), do: args

  defp maybe_add_allowed_tools(args, tools) when is_list(tools) do
    args ++ ["--allowedTools" | [Enum.join(tools, ",")]]
  end
end
