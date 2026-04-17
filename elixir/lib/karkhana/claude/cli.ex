defmodule Karkhana.Claude.CLI do
  @moduledoc """
  Runs coding agents (Pi or Claude Code) inside bhatti sandboxes.

  Uses bhatti's streaming exec endpoint — the HTTP response stays open
  for the duration of the agent run, delivering NDJSON events as they
  arrive. No setsid, no file polling, no shell escaping.
  """

  require Logger

  alias Karkhana.Bhatti.Client, as: Bhatti
  alias Karkhana.Claude.StreamParser
  alias Karkhana.Config

  @prompt_file "/tmp/karkhana-prompt.txt"
  @session_dir "/home/lohar/karkhana-sessions"

  @type run_result :: %{
          session_id: String.t() | nil,
          exit_code: integer(),
          usage: map() | nil
        }

  @spec run(String.t(), String.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(prompt, sandbox_id, opts \\ []) do
    args = build_first_turn_args(prompt, opts)
    execute(args, sandbox_id, opts)
  end

  @spec resume(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, run_result()} | {:error, term()}
  def resume(session_id, prompt, sandbox_id, opts \\ []) do
    args = build_resume_args(session_id, prompt, opts)
    execute(args, sandbox_id, opts)
  end

  defp execute(args, sandbox_id, opts) do
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, Config.settings!().claude.turn_timeout_ms)

    # Write the prompt to a file inside the sandbox to avoid shell escaping.
    # The prompt contains markdown, URLs, parens, quotes — anything that
    # would break shell interpolation.
    {prompt, other_args} = extract_prompt(args)

    # If --continue is in the args but the session dir doesn't exist
    # (sandbox was destroyed and recreated between turns), fall back
    # to a fresh invocation instead of failing silently.
    other_args = if "--continue" in other_args do
      case Bhatti.exec(sandbox_id, ["test", "-d", @session_dir], timeout_sec: 5) do
        {:ok, %{"exit_code" => 0}} ->
          other_args
        _ ->
          Logger.warning("Session dir missing in sandbox #{sandbox_id}, falling back to fresh invocation")
          List.delete(other_args, "--continue")
      end
    else
      other_args
    end

    with :ok <- Bhatti.write_file(sandbox_id, @prompt_file, prompt) do
      command = Config.settings!().claude.command
      plain_args = Enum.join(other_args, " ")
      shell_cmd = "#{command} -p \"$(cat #{@prompt_file})\" #{plain_args}"

      Logger.info("Agent exec in sandbox #{sandbox_id}: #{String.slice(shell_cmd, 0, 120)}...")

      # Use detached exec: bhatti launches the process and returns immediately
      # with a PID and output file. We poll the output file for NDJSON events.
      # This avoids Cloudflare 524 timeouts on long-running agent sessions.
      case Bhatti.exec_detached(sandbox_id, ["bash", "-lc", shell_cmd],
             timeout_sec: div(turn_timeout_ms, 1000)) do
        {:ok, %{"output_file" => output_file, "pid" => _pid}} ->
          poll_output(sandbox_id, output_file, on_event, turn_timeout_ms)

        {:ok, %{"detached" => true} = resp} ->
          output_file = resp["output_file"]
          poll_output(sandbox_id, output_file, on_event, turn_timeout_ms)

        {:error, reason} ->
          {:error, {:launch_failed, reason}}
      end
    end
  end

  @poll_interval_ms 3_000

  defp poll_output(sandbox_id, output_file, on_event, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_loop(sandbox_id, output_file, on_event, deadline, 0, %{session_id: nil, usage: nil})
  end

  defp poll_loop(sandbox_id, output_file, on_event, deadline, lines_seen, state) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      Bhatti.exec(sandbox_id, ["bash", "-c", "pkill -f 'pi\\|claude' 2>/dev/null"], timeout_sec: 5)
      Logger.error("Agent timed out in sandbox #{sandbox_id}")
      {:error, :turn_timeout}
    else
      Process.sleep(@poll_interval_ms)

      # Read new lines from the output file
      skip_cmd = if lines_seen > 0, do: "tail -n +#{lines_seen + 1}", else: "cat"
      read_cmd = "#{skip_cmd} #{output_file} 2>/dev/null"

      case Bhatti.exec(sandbox_id, ["bash", "-c", read_cmd], timeout_sec: 15) do
        {:ok, %{"exit_code" => 0, "stdout" => stdout}} when byte_size(stdout) > 0 ->
          lines = String.split(stdout, "\n", trim: true)
          new_state = process_lines(lines, on_event, state)
          new_lines_seen = lines_seen + length(lines)
          poll_loop(sandbox_id, output_file, on_event, deadline, new_lines_seen, new_state)

        _ ->
          # Check if the process is still running
          case Bhatti.exec(sandbox_id, ["bash", "-c",
                 "test -f #{output_file} && ! pgrep -f 'pi\\|claude' > /dev/null && echo done || echo running"],
                 timeout_sec: 10) do
            {:ok, %{"exit_code" => 0, "stdout" => stdout}} ->
              if String.trim(stdout) == "done" do
                # Process finished — read any remaining output
                case Bhatti.exec(sandbox_id, ["bash", "-c",
                       "tail -n +#{lines_seen + 1} #{output_file} 2>/dev/null"],
                       timeout_sec: 15) do
                  {:ok, %{"exit_code" => 0, "stdout" => final_stdout}} when byte_size(final_stdout) > 0 ->
                    final_lines = String.split(final_stdout, "\n", trim: true)
                    final_state = process_lines(final_lines, on_event, state)
                    {:ok, %{session_id: final_state.session_id, exit_code: 0, usage: final_state.usage}}

                  _ ->
                    {:ok, %{session_id: state.session_id, exit_code: 0, usage: state.usage}}
                end
              else
                poll_loop(sandbox_id, output_file, on_event, deadline, lines_seen, state)
              end

            _ ->
              poll_loop(sandbox_id, output_file, on_event, deadline, lines_seen, state)
          end
      end
    end
  end

  defp process_lines(lines, on_event, state) do
    Enum.reduce(lines, state, fn line, acc ->
      case StreamParser.parse_line(line) do
        {:ok, event} ->
          session_id = StreamParser.extract_session_id(event) || acc.session_id
          usage = StreamParser.extract_usage(event) || acc.usage
          on_event.(event)
          %{acc | session_id: session_id, usage: usage}

        {:error, _} ->
          acc
      end
    end)
  end

  defp extract_prompt(args), do: extract_prompt(args, [])
  defp extract_prompt(["-p", prompt | rest], acc), do: {prompt, Enum.reverse(acc) ++ rest}
  defp extract_prompt([arg | rest], acc), do: extract_prompt(rest, [arg | acc])
  defp extract_prompt([], acc), do: {"", Enum.reverse(acc)}

  defp build_first_turn_args(prompt, opts) do
    settings = Config.settings!().claude
    command = settings.command || "pi"

    case detect_agent(command) do
      :pi -> build_pi_args(prompt, settings, opts)
      :claude -> build_claude_args(prompt, settings)
    end
  end

  defp build_resume_args(_session_id, prompt, opts) do
    # pi doesn't support --resume; each turn is independent.
    # Claude supports --resume but we use pi now.
    # For both: just send the prompt as a new invocation.
    build_first_turn_args(prompt, opts)
  end

  defp build_pi_args(prompt, settings, opts) do
    attempt = Keyword.get(opts, :attempt)
    continuation = is_integer(attempt) and attempt > 0

    base = [
      "-p", prompt,
      "--mode", "json",
      "--session-dir", @session_dir
    ]

    base = if continuation, do: base ++ ["--continue"], else: base

    base
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
