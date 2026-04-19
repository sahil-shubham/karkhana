defmodule Karkhana.Gate do
  @moduledoc """
  Runs quality gates in a sandbox.

  Gates are quality checkpoints defined in mode configs. Each gate has a
  check type (artifact_exists, content_match, command, script) and a
  failure response (retry_with_feedback, warn, block_for_human).

  Gates run in order. A `:fail` result short-circuits — later gates are
  skipped. `:warn` results are collected but don't block.

  ## Gate spec format

  Each gate is a map with at minimum:
    - `"name"` — human-readable identifier
    - `"check"` — one of: "artifact_exists", "content_match", "command", "script"
    - `"on_failure"` — one of: "retry_with_feedback", "warn", "block_for_human"

  Type-specific fields:
    - artifact_exists: `"artifact"` name (resolved via context.artifacts)
    - content_match: `"artifact"` name + `"pattern"` regex
    - command: `"command"` shell command string
    - script: `"script"` path relative to .karkhana/ dir

  Optional:
    - `"message"` — human-readable failure message (used when check gives no output)
    - `"timeout_sec"` — execution timeout (default 120)
  """

  require Logger

  alias Karkhana.Bhatti.Client, as: Bhatti

  @default_timeout_sec 120

  @type check_type :: :artifact_exists | :content_match | :command | :script
  @type failure_response :: :retry_with_feedback | :warn | :block_for_human
  @type result :: {String.t(), :pass | :fail | :warn, String.t()}

  @type gate_spec :: %{
          optional(String.t()) => term()
        }

  @type context :: %{
          sandbox_id: String.t(),
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          mode: String.t() | nil,
          attempt: integer() | nil,
          protocol_dir: String.t() | nil,
          artifacts: %{String.t() => %{String.t() => term()}} | nil
        }

  @doc """
  Run a list of gates against a sandbox.

  Returns `{:all_passed, results}` if every gate passed (or warned),
  or `{:failed, results}` if any gate hard-failed.

  Gates run in order. First `:fail` stops execution — remaining gates
  are not run. `:warn` gates are recorded but don't stop.
  """
  @spec run_gates([gate_spec()], context()) :: {:all_passed, [result()]} | {:failed, [result()]}
  def run_gates([], _context), do: {:all_passed, []}

  def run_gates(gates, context) when is_list(gates) do
    run_gates_seq(gates, context, [])
  end

  @doc """
  Extract failure feedback from gate results for injection into the
  retry prompt. Returns a list of `%{gate: name, output: message}`.
  """
  @spec failure_feedback([result()]) :: [%{gate: String.t(), output: String.t()}]
  def failure_feedback(results) when is_list(results) do
    results
    |> Enum.filter(fn {_name, status, _output} -> status == :fail end)
    |> Enum.map(fn {name, :fail, output} -> %{gate: name, output: output} end)
  end

  # --- Sequential gate execution ---

  defp run_gates_seq([], _context, acc) do
    results = Enum.reverse(acc)

    if Enum.any?(results, fn {_name, status, _output} -> status == :fail end) do
      {:failed, results}
    else
      {:all_passed, results}
    end
  end

  defp run_gates_seq([gate | rest], context, acc) do
    result = run_one(gate, context)
    {_name, status, _output} = result

    case status do
      :fail ->
        # Short-circuit: don't run remaining gates
        {:failed, Enum.reverse([result | acc])}

      _ ->
        # :pass or :warn — continue
        run_gates_seq(rest, context, [result | acc])
    end
  end

  # --- Individual gate execution ---

  defp run_one(gate, context) do
    name = gate_name(gate)
    check = gate["check"]
    sandbox_id = context.sandbox_id

    case check do
      "artifact_exists" ->
        run_artifact_exists(name, gate, sandbox_id, context)

      "content_match" ->
        run_content_match(name, gate, sandbox_id, context)

      "command" ->
        run_command(name, gate, sandbox_id, context)

      "script" ->
        run_script(name, gate, sandbox_id, context)

      other ->
        Logger.warning("Unknown gate check type: #{inspect(other)} for gate #{name}")
        {name, :fail, "Unknown gate check type: #{inspect(other)}"}
    end
  end

  # --- Gate type implementations ---

  defp run_artifact_exists(name, gate, sandbox_id, context) do
    path = resolve_artifact_path(gate["artifact"], context)

    if is_nil(path) do
      {name, :fail, failure_message(gate, "Artifact '#{gate["artifact"]}' has no configured path", context)}
    else
      cmd = "test -f #{escape_path(path)} -o -d #{escape_path(path)}"

      if Bhatti.exec_check(sandbox_id, cmd, timeout_sec: 10) do
        {name, :pass, "Artifact exists at #{path}"}
      else
        {name, maybe_warn(gate), failure_message(gate, "Artifact not found at #{path}", context)}
      end
    end
  end

  defp run_content_match(name, gate, sandbox_id, context) do
    path = resolve_artifact_path(gate["artifact"], context)
    pattern = gate["pattern"]

    cond do
      is_nil(path) ->
        {name, :fail, failure_message(gate, "Artifact '#{gate["artifact"]}' has no configured path", context)}

      is_nil(pattern) ->
        {name, :fail, "Gate #{name}: content_match requires a 'pattern'"}

      true ->
        cmd = "grep -qP #{escape_arg(pattern)} #{escape_path(path)}"

        if Bhatti.exec_check(sandbox_id, cmd, timeout_sec: 10) do
          {name, :pass, "Pattern matched in #{path}"}
        else
          {name, maybe_warn(gate), failure_message(gate, "Pattern '#{pattern}' not found in #{path}", context)}
        end
    end
  end

  defp run_command(name, gate, sandbox_id, _context) do
    cmd = gate["command"]

    if is_nil(cmd) or cmd == "" do
      {name, :fail, "Gate #{name}: command check requires a 'command'"}
    else
      timeout = gate["timeout_sec"] || @default_timeout_sec

      case Bhatti.exec(sandbox_id, ["bash", "-c", cmd], timeout_sec: timeout) do
        {:ok, %{"exit_code" => 0, "stdout" => out}} ->
          {name, :pass, String.trim(out || "")}

        {:ok, %{"exit_code" => code} = result} ->
          out = Map.get(result, "stdout", "") <> "\n" <> Map.get(result, "stderr", "")
          {name, maybe_warn(gate), failure_message(gate, "Exit #{code}:\n#{String.trim(out)}")}

        {:error, reason} ->
          {name, :fail, "Gate execution failed: #{inspect(reason)}"}
      end
    end
  end

  defp run_script(name, gate, sandbox_id, context) do
    script_path = gate["script"]
    protocol_dir = context[:protocol_dir]

    cond do
      is_nil(script_path) ->
        {name, :fail, "Gate #{name}: script check requires a 'script' path"}

      is_nil(protocol_dir) ->
        {name, :fail, "Gate #{name}: no protocol directory configured for script resolution"}

      true ->
        full_path = Path.join(protocol_dir, script_path)

        case File.read(full_path) do
          {:ok, script_content} ->
            timeout = gate["timeout_sec"] || @default_timeout_sec
            env_prefix = gate_env_script(context)
            full_script = env_prefix <> "\n" <> script_content

            case Bhatti.exec(sandbox_id, ["bash", "-c", full_script], timeout_sec: timeout) do
              {:ok, %{"exit_code" => 0, "stdout" => out}} ->
                {name, :pass, String.trim(out || "")}

              {:ok, %{"exit_code" => code} = result} ->
                out = Map.get(result, "stdout", "") <> "\n" <> Map.get(result, "stderr", "")
                {name, maybe_warn(gate), failure_message(gate, "Exit #{code}:\n#{String.trim(out)}")}

              {:error, reason} ->
                {name, :fail, "Gate execution failed: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {name, :fail, "Gate script not found at #{full_path}: #{inspect(reason)}"}
        end
    end
  end

  # --- Helpers ---

  defp gate_name(gate) do
    gate["name"] || gate["check"] || "unnamed"
  end

  defp failure_message(gate, default, context \\ %{}) do
    msg = gate["message"] || default
    render_template(msg, context)
  end

  defp maybe_warn(gate) do
    if gate["on_failure"] == "warn", do: :warn, else: :fail
  end

  defp resolve_artifact_path(nil, _context), do: nil

  defp resolve_artifact_path(artifact_name, context) do
    case get_in(context, [:artifacts, artifact_name]) do
      %{"paths" => [path | _]} -> render_template(path, context)
      _ -> nil
    end
  end

  # Render Liquid/Solid templates in gate paths and messages.
  # Supports {{ issue.identifier }} etc.
  defp render_template(text, context) when is_binary(text) do
    if String.contains?(text, "{{") do
      try do
        text
        |> Solid.parse!()
        |> Solid.render!(%{"issue" => %{"identifier" => context[:issue_identifier] || ""}})
        |> IO.iodata_to_binary()
      rescue
        _ -> text
      end
    else
      text
    end
  end

  defp render_template(text, _context), do: text

  defp gate_env_script(context) do
    vars = [
      {"KARKHANA_ISSUE_ID", context[:issue_id]},
      {"KARKHANA_ISSUE_IDENTIFIER", context[:issue_identifier]},
      {"KARKHANA_MODE", context[:mode]},
      {"KARKHANA_ATTEMPT", context[:attempt] && to_string(context[:attempt])},
      {"KARKHANA_WORKSPACE", "/workspace"}
    ]

    vars
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map_join("\n", fn {k, v} -> "export #{k}=#{escape_arg(v)}" end)
  end

  defp escape_path(path) when is_binary(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end

  defp escape_arg(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end
end
