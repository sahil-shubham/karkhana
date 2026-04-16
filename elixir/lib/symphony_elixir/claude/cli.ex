defmodule SymphonyElixir.Claude.CLI do
  @moduledoc """
  Runs coding agents (Pi or Claude Code) inside bhatti sandboxes.

  Uses bhatti's streaming exec endpoint — the HTTP response stays open
  for the duration of the agent run, delivering NDJSON events as they
  arrive. No setsid, no file polling, no shell escaping.
  """

  require Logger

  alias SymphonyElixir.Bhatti.Client, as: Bhatti
  alias SymphonyElixir.Claude.StreamParser
  alias SymphonyElixir.Config

  @prompt_file "/tmp/karkhana-prompt.txt"
  @system_prompt_file "/tmp/karkhana-system-prompt.txt"
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

    # Handle role config: may need to write system prompt file to sandbox
    role_config = Keyword.get(opts, :role_config)
    {role_setup, role_args} = role_config_args(role_config)
    other_args = other_args ++ role_args

    with :ok <- Bhatti.write_file(sandbox_id, @prompt_file, prompt),
         :ok <- write_role_files(sandbox_id, role_setup) do
      command = Config.settings!().claude.command

      # Build the shell command. other_args are simple flags (--mode, --model, etc.)
      # The prompt and system prompt are read from files via $(cat ...) to avoid escaping.
      plain_args = Enum.join(other_args, " ")

      system_prompt_part =
        if Enum.any?(role_setup, &match?({:write_system_prompt, _}, &1)) do
          " --append-system-prompt \"$(cat #{@system_prompt_file})\""
        else
          ""
        end

      shell_cmd = "#{command} -p \"$(cat #{@prompt_file})\"#{system_prompt_part} #{plain_args}"

      cmd = ["bash", "-lc", shell_cmd]

      Logger.info("Agent exec in sandbox #{sandbox_id}: #{String.slice(shell_cmd, 0, 120)}...")

      # Track session_id and usage across the stream via process dictionary.
      # This runs in a Task (one per agent dispatch), so the process dictionary
      # is scoped and cleaned up on exit.
      Process.put(:karkhana_session_id, nil)
      Process.put(:karkhana_usage, nil)

      on_line = fn line ->
        case StreamParser.parse_line(line) do
          {:ok, event} ->
            sid = StreamParser.extract_session_id(event)
            if sid, do: Process.put(:karkhana_session_id, sid)

            usage = StreamParser.extract_usage(event)
            if usage, do: Process.put(:karkhana_usage, usage)

            on_event.(event)

          {:error, _} ->
            # Non-JSON line (stderr mixed in, debug output, etc.) — skip
            :ok
        end
      end

      result = Bhatti.exec_stream(sandbox_id, cmd, on_line,
        timeout_sec: div(turn_timeout_ms, 1000))

      session_id = Process.get(:karkhana_session_id)
      usage = Process.get(:karkhana_usage)

      case result do
        {:ok, 0} ->
          {:ok, %{session_id: session_id, exit_code: 0, usage: usage}}

        {:ok, exit_code} ->
          Logger.error("Agent exited with code #{exit_code} in sandbox #{sandbox_id}")
          {:error, {:subprocess_exit, exit_code, ""}}

        {:error, :timeout} ->
          Logger.error("Agent timed out in sandbox #{sandbox_id}")
          Bhatti.exec(sandbox_id, ["bash", "-c", "pkill -f 'pi\\|claude' 2>/dev/null"], timeout_sec: 5)
          {:error, :turn_timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp write_role_files(_sandbox_id, []), do: :ok
  defp write_role_files(sandbox_id, setup_cmds) do
    Enum.reduce_while(setup_cmds, :ok, fn
      {:write_system_prompt, content}, :ok ->
        case Bhatti.write_file(sandbox_id, @system_prompt_file, content) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
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

  # Role config is handled specially: the system prompt content is written
  # to a file in the sandbox (like the main prompt) to avoid shell escaping.
  # Returns {extra_setup_cmds, extra_args}
  defp role_config_args(nil), do: {[], []}
  defp role_config_args(config) when is_map(config) do
    extra_args =
      []
      |> maybe_add_option(config[:thinking], "--thinking")
      |> maybe_add_option(config[:tools], "--tools")

    # If there's a system prompt file, we'll write it and reference it
    has_system_prompt = config[:system_prompt_file] && File.exists?(config[:system_prompt_file])

    if has_system_prompt do
      {[{:write_system_prompt, File.read!(config[:system_prompt_file])}], extra_args}
    else
      {[], extra_args}
    end
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
