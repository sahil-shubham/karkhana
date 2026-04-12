defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue bhatti sandboxes.
  Each issue gets a sandbox named `karkhana-<sanitized_identifier>`.
  """

  require Logger
  alias SymphonyElixir.{Config, Bhatti.Client}
  alias SymphonyElixir.Linear.Issue

  @sandbox_prefix "karkhana-"

  @spec create_for_issue(map()) :: {:ok, String.t()} | {:error, term()}
  def create_for_issue(issue) do
    safe_id = safe_identifier(issue)
    sandbox_name = @sandbox_prefix <> safe_id

    Logger.info("Ensuring sandbox for #{issue_log(issue)} name=#{sandbox_name}")

    case find_sandbox_by_name(sandbox_name) do
      {:ok, %{"id" => sandbox_id}} ->
        Logger.info("Reusing existing sandbox #{sandbox_name} id=#{sandbox_id}")
        {:ok, sandbox_id}

      :not_found ->
        create_new_sandbox(sandbox_name, issue)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run_before_run_hook(String.t(), map()) :: :ok | {:error, term()}
  def run_before_run_hook(sandbox_id, issue) do
    run_hook(sandbox_id, Config.settings!().hooks.before_run, "before_run", issue)
  end

  @spec run_after_run_hook(String.t(), map()) :: :ok
  def run_after_run_hook(sandbox_id, issue) do
    case run_hook(sandbox_id, Config.settings!().hooks.after_run, "after_run", issue) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("after_run hook failed for #{issue_log(issue)}: #{inspect(reason)}")
        :ok
    end
  end

  @spec cleanup_sandbox(String.t()) :: :ok | {:error, term()}
  def cleanup_sandbox(sandbox_name) when is_binary(sandbox_name) do
    case find_sandbox_by_name(sandbox_name) do
      {:ok, %{"id" => sandbox_id}} ->
        # Run before_remove hook best-effort
        hook = Config.settings!().hooks.before_remove
        if hook do
          run_hook_raw(sandbox_id, hook, "before_remove")
        end

        Client.destroy_sandbox(sandbox_id)

      :not_found ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec cleanup_for_issue(map()) :: :ok | {:error, term()}
  def cleanup_for_issue(issue) do
    safe_id = safe_identifier(issue)
    cleanup_sandbox(@sandbox_prefix <> safe_id)
  end

  @spec sandbox_name_for_issue(map()) :: String.t()
  def sandbox_name_for_issue(issue) do
    @sandbox_prefix <> safe_identifier(issue)
  end

  # --- private ---

  defp create_new_sandbox(sandbox_name, _issue) do
    settings = Config.settings!()
    bhatti = settings.bhatti

    # Pass credentials into the sandbox:
    # - GH_TOKEN for git push + gh pr create
    # - LINEAR_API_KEY for reading/writing Linear comments
    # - ANTHROPIC_API_KEY for Claude (if using API key auth; OAuth uses ~/.claude.json)
    env =
      %{}
      |> maybe_put_env("ANTHROPIC_API_KEY", System.get_env("ANTHROPIC_API_KEY"))
      |> maybe_put_env("GH_TOKEN", System.get_env("GH_TOKEN"))
      |> maybe_put_env("GITHUB_TOKEN", System.get_env("GH_TOKEN"))
      |> maybe_put_env("LINEAR_API_KEY", System.get_env("LINEAR_API_KEY"))

    spec = %{
      "name" => sandbox_name,
      "image" => bhatti.image,
      "cpus" => bhatti.cpus,
      "memory_mb" => bhatti.memory_mb,
      "disk_size_mb" => bhatti.disk_mb,
      "env" => env,
      "keep_hot" => true
    }

    spec =
      if bhatti.volume do
        Map.put(spec, "persistent_volumes", [
          %{"name" => bhatti.volume, "mount" => "/workspace", "size_mb" => bhatti.disk_mb, "auto_create" => true}
        ])
      else
        spec
      end

    case Client.create_sandbox(spec) do
      {:ok, %{"id" => sandbox_id}} ->
        Logger.info("Created sandbox #{sandbox_name} id=#{sandbox_id}")

        # Run after_create hook first (installs claude CLI etc)
        hook = settings.hooks.after_create
        hook_result = if hook do
          run_hook_raw(sandbox_id, hook, "after_create")
        else
          :ok
        end

        case hook_result do
          :ok ->
            {:ok, sandbox_id}

          {:error, reason} ->
            Logger.error("after_create hook failed, destroying sandbox #{sandbox_name}: #{inspect(reason)}")
            Client.destroy_sandbox(sandbox_id)
            {:error, {:after_create_hook_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_sandbox_by_name(name) do
    case Client.list_sandboxes() do
      {:ok, sandboxes} ->
        case Enum.find(sandboxes, fn sb -> sb["name"] == name end) do
          nil -> :not_found
          sandbox -> {:ok, sandbox}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_hook(_sandbox_id, nil, _name, _issue), do: :ok
  defp run_hook(_sandbox_id, "", _name, _issue), do: :ok

  defp run_hook(sandbox_id, script, name, issue) do
    Logger.info("Running #{name} hook for #{issue_log(issue)}")
    run_hook_raw(sandbox_id, script, name)
  end

  defp run_hook_raw(sandbox_id, script, name) do
    timeout_sec = div(Config.settings!().hooks.timeout_ms, 1000)

    case Client.exec(sandbox_id, ["bash", "-lc", script], timeout_sec: timeout_sec) do
      {:ok, %{"exit_code" => 0}} ->
        :ok

      {:ok, %{"exit_code" => code, "stderr" => stderr}} ->
        {:error, {:hook_failed, name, code, stderr}}

      {:ok, %{"exit_code" => code}} ->
        {:error, {:hook_failed, name, code, ""}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_identifier(%Issue{identifier: id}) when is_binary(id), do: sanitize(id)
  defp safe_identifier(%{identifier: id}) when is_binary(id), do: sanitize(id)
  defp safe_identifier(id) when is_binary(id), do: sanitize(id)

  defp sanitize(id) do
    String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")
  end

  defp maybe_put_env(map, _key, nil), do: map
  defp maybe_put_env(map, _key, ""), do: map
  defp maybe_put_env(map, key, value), do: Map.put(map, key, value)

  defp issue_log(%Issue{id: id, identifier: ident}), do: "issue_id=#{id} issue_identifier=#{ident}"
  defp issue_log(%{id: id, identifier: ident}), do: "issue_id=#{id} issue_identifier=#{ident}"
  defp issue_log(other), do: inspect(other)
end
