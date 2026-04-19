defmodule Karkhana.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in a bhatti sandbox with Claude Code.
  """

  require Logger
  alias Karkhana.Claude.CLI, as: ClaudeCLI
  alias Karkhana.Claude.StreamParser
  alias Karkhana.{Config, Linear.Issue, Protocol, PromptBuilder, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, claude_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue(issue) do
      {:ok, sandbox_id} ->
        try do
          # Resolve mode from .karkhana/ protocol or fall back to default
          {mode, mode_prompt} = resolve_mode(sandbox_id, issue)
          opts = Keyword.merge(opts, mode: mode, mode_prompt: mode_prompt)

          # Report mode to orchestrator for tracking
          send_runtime_info(claude_update_recipient, issue, %{
            mode: mode,
            sandbox_id: sandbox_id
          })

          Logger.info("Resolved mode=#{mode} for #{issue_context(issue)}")

          with :ok <- Workspace.run_before_run_hook(sandbox_id, issue),
               :ok <- send_phase_update(claude_update_recipient, issue, :claude_starting),
               :ok <- run_claude_turns(sandbox_id, issue, claude_update_recipient, opts),
               :ok <- run_gate(sandbox_id, issue, opts, claude_update_recipient) do
            :ok
          else
            {:error, reason} ->
              Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(sandbox_id, issue)
        end

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp claude_event_handler(recipient, issue) do
    fn event ->
      send_claude_update(recipient, issue, event)
    end
  end

  defp send_claude_update(recipient, %Issue{id: issue_id}, event)
       when is_binary(issue_id) and is_pid(recipient) do
    timestamp = DateTime.utc_now()
    session_id = StreamParser.extract_session_id(event)
    usage = StreamParser.extract_usage(event)
    event_type = Map.get(event, :event_type, :unknown)

    send(
      recipient,
      {:agent_worker_update, issue_id,
       %{
         event: event_type,
         timestamp: timestamp,
         session_id: session_id,
         usage: usage,
         raw: event
       }}
    )

    :ok
  end

  defp send_claude_update(_recipient, _issue, _event), do: :ok

  defp send_phase_update(recipient, %Issue{id: issue_id}, phase)
       when is_pid(recipient) and is_atom(phase) do
    send(
      recipient,
      {:agent_worker_update, issue_id,
       %{
         event: phase,
         timestamp: DateTime.utc_now(),
         session_id: nil,
         usage: nil,
         raw: %{}
       }}
    )

    :ok
  end

  defp send_phase_update(_recipient, _issue, _phase), do: :ok

  defp run_claude_turns(sandbox_id, issue, claude_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    # Check for a previous session to resume (cross-dispatch continuity)
    previous_session_id = lookup_previous_session(issue)
    do_run_claude_turns(sandbox_id, issue, claude_update_recipient, opts, issue_state_fetcher, 1, max_turns, previous_session_id)
  end

  defp do_run_claude_turns(sandbox_id, issue, claude_update_recipient, opts, issue_state_fetcher, turn_number, max_turns, session_id) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    attempt = Keyword.get(opts, :attempt)

    cli_opts = [
      on_event: claude_event_handler(claude_update_recipient, issue),
      attempt: attempt
    ]

    result =
      if session_id == nil do
        ClaudeCLI.run(prompt, sandbox_id, cli_opts)
      else
        ClaudeCLI.resume(session_id, prompt, sandbox_id, cli_opts)
      end

    case result do
      {:ok, %{session_id: new_session_id}} ->
        effective_session_id = new_session_id || session_id
        Logger.info("Completed agent turn for #{issue_context(issue)} session_id=#{effective_session_id} turn=#{turn_number}/#{max_turns}")

        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} turn=#{turn_number}/#{max_turns}")

            do_run_claude_turns(
              sandbox_id,
              refreshed_issue,
              claude_update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns,
              effective_session_id
            )

          {:continue, _refreshed_issue} ->
            :ok

          {:done, _refreshed_issue} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this session, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = String.downcase(String.trim(state_name))

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active -> String.downcase(String.trim(active)) == normalized_state end)
  end

  defp active_issue_state?(_), do: false

  defp run_gate(sandbox_id, issue, opts, recipient) do
    mode = Keyword.get(opts, :mode, "default")
    workspace = Config.settings!().workspace.root

    gate_script =
      case Protocol.load(workspace) do
        {:ok, protocol} ->
          # Find the gate for the current mode
          matched =
            Enum.find(protocol.modes, fn m ->
              mode_name_matches?(m, mode)
            end)

          if matched && matched.gate do
            gate_path = Path.join(protocol.dir, matched.gate)

            case File.read(gate_path) do
              {:ok, script} -> script
              {:error, _} -> nil
            end
          end

        {:error, _} ->
          nil
      end

    if gate_script do
      Logger.info("Running gate for mode=#{mode} #{issue_context(issue)}")

      case Karkhana.Bhatti.Client.exec(sandbox_id, ["bash", "-c", gate_script], timeout_sec: 60) do
        {:ok, %{"exit_code" => 0, "stdout" => output}} ->
          Logger.info("Gate passed for #{issue_context(issue)}: #{String.trim(output)}")
          send_gate_result(recipient, issue, mode, :pass, String.trim(output))
          :ok

        {:ok, %{"exit_code" => code} = result} ->
          output = Map.get(result, "stdout", "") <> "\n" <> Map.get(result, "stderr", "")
          Logger.warning("Gate failed (exit #{code}) for #{issue_context(issue)}: #{String.trim(output)}")
          send_gate_result(recipient, issue, mode, :fail, String.trim(output))
          {:error, {:gate_failed, mode, code, String.trim(output)}}

        {:error, reason} ->
          Logger.warning("Gate exec failed for #{issue_context(issue)}: #{inspect(reason)}")
          send_gate_result(recipient, issue, mode, :fail, inspect(reason))
          {:error, {:gate_failed, mode, :exec_error, inspect(reason)}}
      end
    else
      # No gate defined for this mode — pass through
      :ok
    end
  end

  defp mode_name_matches?(%{match: %{"label" => label}}, mode), do: label == mode

  defp mode_name_matches?(%{prompt: prompt}, mode) when is_binary(prompt) do
    prompt |> Path.basename() |> Path.rootname() == mode
  end

  defp mode_name_matches?(_, _), do: false

  defp send_gate_result(recipient, %Issue{id: issue_id}, mode, result, output)
       when is_pid(recipient) and is_binary(issue_id) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         gate: mode,
         gate_result: result,
         gate_output: output
       }}
    )
  end

  defp send_gate_result(_, _, _, _, _), do: :ok

  defp lookup_previous_session(%Issue{identifier: identifier}) when is_binary(identifier) do
    case Karkhana.Store.last_session_id(identifier) do
      {:ok, session_id} when is_binary(session_id) ->
        Logger.info("Found previous session #{session_id} for #{identifier}")
        session_id

      _ ->
        nil
    end
  end

  defp lookup_previous_session(_), do: nil

  defp resolve_mode(sandbox_id, issue) do
    workspace = Config.settings!().workspace.root

    case Protocol.load(workspace) do
      {:ok, protocol} ->
        # Build an artifact checker that execs into the sandbox
        checker = fn cmd ->
          Karkhana.Bhatti.Client.exec_check(sandbox_id, cmd)
        end

        mode = Protocol.resolve_mode(protocol, issue, checker)
        {mode.name, mode.prompt_content}

      {:error, :not_found} ->
        # No .karkhana/ — use WORKFLOW.md with label-based mode hint
        mode_from_labels(issue)

      {:error, reason} ->
        Logger.warning("Failed to load .karkhana/ protocol: #{inspect(reason)}; using default mode")
        {"default", nil}
    end
  end

  defp mode_from_labels(%Issue{labels: labels}) when is_list(labels) do
    cond do
      "qa" in labels -> {"qa", nil}
      "debug" in labels -> {"debugging", nil}
      "plan" in labels -> {"planning", nil}
      true -> {"default", nil}
    end
  end

  defp mode_from_labels(_), do: {"default", nil}

  defp send_runtime_info(recipient, %Issue{id: issue_id}, info)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:worker_runtime_info, issue_id, info})
  end

  defp send_runtime_info(_, _, _), do: :ok

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
