defmodule Karkhana.Protocol do
  @moduledoc """
  Loads and resolves the .karkhana/ protocol directory.

  The protocol defines modes, artifact conventions, and gate scripts.
  Mode resolution checks issue labels first (human override), then
  artifact state in the sandbox.

  Falls back to nil when no .karkhana/ directory exists — the caller
  uses WORKFLOW.md directly.
  """

  require Logger
  alias Karkhana.Linear.Issue

  @karkhana_dir ".karkhana"
  @workflow_yaml "workflow.yaml"
  @default_mode "default"

  defstruct [:config, :dir, :modes, :artifacts, :config_hash]

  @type t :: %__MODULE__{
          config: map(),
          dir: String.t(),
          modes: [map()],
          artifacts: map(),
          config_hash: String.t()
        }

  @type mode :: %{
          name: String.t(),
          prompt: String.t(),
          prompt_content: String.t() | nil,
          gate: String.t() | nil,
          match: map() | String.t()
        }

  @doc """
  Load the .karkhana/ protocol from a project directory (inside a sandbox).
  Returns {:ok, protocol} or {:error, :not_found} if no .karkhana/ exists.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(project_path) do
    dir = Path.join(project_path, @karkhana_dir)
    yaml_path = Path.join(dir, @workflow_yaml)

    with true <- File.dir?(dir),
         {:ok, content} <- File.read(yaml_path),
         {:ok, parsed} <- YamlElixir.read_from_string(content) do
      modes = parse_modes(parsed["modes"] || [])
      artifacts = parsed["artifacts"] || %{}
      hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> binary_part(0, 12)

      protocol = %__MODULE__{
        config: parsed,
        dir: dir,
        modes: modes,
        artifacts: artifacts,
        config_hash: hash
      }

      {:ok, protocol}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolve which mode applies for a given issue.
  Checks mode rules in order — first match wins.

  Returns the matched mode map with :prompt_content loaded from disk,
  or a default mode if nothing matches.
  """
  @spec resolve_mode(t(), Issue.t(), (String.t() -> boolean()) | nil) :: mode()
  def resolve_mode(%__MODULE__{} = protocol, %Issue{} = issue, artifact_checker \\ nil) do
    labels = Issue.label_names(issue)

    # Pre-compute which artifacts exist so mode rules can reference by name
    existing_artifacts =
      if artifact_checker do
        check_artifacts(protocol, artifact_checker) |> MapSet.new()
      else
        MapSet.new()
      end

    matched =
      Enum.find(protocol.modes, fn mode ->
        matches_rule?(mode.match, labels, existing_artifacts)
      end)

    mode = matched || default_mode()

    # Load the prompt content from disk
    prompt_content =
      if mode.prompt do
        prompt_path = Path.join(protocol.dir, mode.prompt)

        case File.read(prompt_path) do
          {:ok, content} ->
            content

          {:error, reason} ->
            Logger.warning("Failed to load mode prompt #{prompt_path}: #{inspect(reason)}")
            nil
        end
      end

    %{mode | prompt_content: prompt_content, name: mode_name(mode)}
  end

  @doc """
  Check which artifacts exist using the given checker function.
  Returns a list of artifact names that exist.
  """
  @spec check_artifacts(t(), (String.t() -> boolean())) :: [String.t()]
  def check_artifacts(%__MODULE__{artifacts: artifacts}, checker) when is_function(checker, 1) do
    Enum.flat_map(artifacts, fn {name, definition} ->
      paths = definition["paths"] || []
      check_cmd = definition["check"]

      exists =
        cond do
          check_cmd && checker.(check_cmd) -> true
          Enum.any?(paths, &checker.("test -f #{&1} -o -d #{&1}")) -> true
          true -> false
        end

      if exists, do: [name], else: []
    end)
  end

  def check_artifacts(_, _), do: []

  # --- Private ---

  defp parse_modes(modes) when is_list(modes) do
    Enum.map(modes, fn mode ->
      %{
        match: mode["match"] || @default_mode,
        prompt: mode["prompt"],
        prompt_content: nil,
        gate: mode["gate"],
        name: nil
      }
    end)
  end

  defp parse_modes(_), do: []

  defp matches_rule?(@default_mode, _labels, _artifacts), do: true

  defp matches_rule?(%{"label" => label}, labels, _artifacts) when is_binary(label) do
    label in labels
  end

  defp matches_rule?(%{"has_artifact" => name}, _labels, artifacts) do
    MapSet.member?(artifacts, name)
  end

  defp matches_rule?(%{"all" => conditions}, labels, artifacts) when is_list(conditions) do
    Enum.all?(conditions, fn condition ->
      matches_rule?(condition, labels, artifacts)
    end)
  end

  defp matches_rule?(_, _labels, _artifacts), do: false

  defp default_mode do
    %{
      match: @default_mode,
      prompt: nil,
      prompt_content: nil,
      gate: nil,
      name: "default"
    }
  end

  defp mode_name(%{match: %{"label" => label}}), do: label
  defp mode_name(%{prompt: prompt}) when is_binary(prompt), do: prompt_to_name(prompt)
  defp mode_name(_), do: "default"

  defp prompt_to_name(nil), do: "default"

  defp prompt_to_name(path) when is_binary(path) do
    path |> Path.basename() |> Path.rootname()
  end
end
