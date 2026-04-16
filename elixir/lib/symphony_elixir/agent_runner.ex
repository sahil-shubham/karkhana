defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in a bhatti sandbox with Claude Code.
  """

  require Logger
  alias SymphonyElixir.Claude.CLI, as: ClaudeCLI
  alias SymphonyElixir.Claude.StreamParser
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, claude_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue(issue) do
      {:ok, sandbox_id} ->
        try do
          with :ok <- Workspace.run_before_run_hook(sandbox_id, issue),
               :ok <- send_phase_update(claude_update_recipient, issue, :claude_starting),
               :ok <- run_claude_turns(sandbox_id, issue, claude_update_recipient, opts) do
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
    role_config = load_role_config(Keyword.get(opts, :role, "implementer"))
    opts = Keyword.put(opts, :role_config, role_config)

    do_run_claude_turns(sandbox_id, issue, claude_update_recipient, opts, issue_state_fetcher, 1, max_turns, nil)
  end

  defp do_run_claude_turns(sandbox_id, issue, claude_update_recipient, opts, issue_state_fetcher, turn_number, max_turns, session_id) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    attempt = Keyword.get(opts, :attempt)

    cli_opts = [
      on_event: claude_event_handler(claude_update_recipient, issue),
      attempt: attempt,
      role_config: Keyword.get(opts, :role_config)
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

  # Load role configuration from roles/<name>/ directory.
  # Falls back gracefully if the directory doesn't exist (backwards compat).
  defp load_role_config(role_name) when is_binary(role_name) do
    workflow_path = SymphonyElixir.Workflow.workflow_file_path()
    base_dir = Path.dirname(workflow_path)
    role_dir = Path.join(base_dir, "roles/#{role_name}")
    skills_dir = Path.join(base_dir, "skills")

    role_md = Path.join(role_dir, "ROLE.md")
    config_yaml = Path.join(role_dir, "config.yaml")

    if File.exists?(role_md) do
      # Read role prompt (for --append-system-prompt)
      system_prompt_file = role_md

      # Read config.yaml if it exists
      {tools, thinking} =
        if File.exists?(config_yaml) do
          case YamlElixir.read_from_file(config_yaml) do
            {:ok, config} ->
              tools = case config["tools"] do
                list when is_list(list) -> Enum.join(list, ",")
                _ -> nil
              end
              {tools, config["thinking"]}

            _ -> {nil, nil}
          end
        else
          {nil, nil}
        end

      # Collect skill directories
      skill_dirs = if File.dir?(skills_dir) do
        File.ls!(skills_dir)
        |> Enum.map(&Path.join(skills_dir, &1))
        |> Enum.filter(&File.dir?/1)
      else
        []
      end

      Logger.info("Loaded role config: #{role_name} (#{length(skill_dirs)} skills)")

      %{
        name: role_name,
        system_prompt_file: system_prompt_file,
        tools: tools,
        thinking: thinking,
        skill_dirs: skill_dirs
      }
    else
      Logger.debug("No role directory for #{role_name}, using WORKFLOW.md prompt")
      nil
    end
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = String.downcase(String.trim(state_name))

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active -> String.downcase(String.trim(active)) == normalized_state end)
  end

  defp active_issue_state?(_), do: false

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
