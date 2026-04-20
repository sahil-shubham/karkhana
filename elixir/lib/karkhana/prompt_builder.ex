defmodule Karkhana.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.

  Supports two modes:
  - Standard: renders the WORKFLOW.md prompt template
  - Protocol: renders a mode-specific prompt from .karkhana/modes/

  In both cases, the template receives {{ issue.* }}, {{ attempt }},
  and {{ mode }} variables. Labels are available as {{ issue.labels }}.
  """

  alias Karkhana.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(Karkhana.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    mode = Keyword.get(opts, :mode)
    mode_prompt = Keyword.get(opts, :mode_prompt)
    gate_feedback = Keyword.get(opts, :gate_feedback)

    template =
      if mode_prompt do
        parse_template!(mode_prompt)
      else
        Workflow.current() |> prompt_template!() |> parse_template!()
      end

    documents = Keyword.get(opts, :documents, %{})

    base_prompt =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "mode" => mode || "default",
          "issue" => issue |> Map.from_struct() |> to_solid_map(),
          "documents" => to_solid_map(documents)
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    if gate_feedback do
      base_prompt <> build_feedback_section(gate_feedback, Keyword.get(opts, :attempt))
    else
      base_prompt
    end
  end

  @doc """
  Build a feedback section from gate failure results.
  Appended to the prompt when retrying after gate failures.
  """
  @spec build_feedback_section([%{gate: String.t(), output: String.t()}], integer() | nil) :: String.t()
  def build_feedback_section(gate_feedback, attempt \\ nil) do
    if gate_feedback == [] do
      ""
    else
      feedback_items =
        gate_feedback
        |> Enum.map_join("\n\n", fn %{gate: name, output: output} ->
          "**Gate '#{name}' failed:**\n#{output}"
        end)

      attempt_note = if attempt, do: " (attempt #{attempt})", else: ""

      """


      ---

      ## Feedback from previous attempt#{attempt_note}

      The previous attempt failed quality gates. Address each one:

      #{feedback_items}

      Focus on fixing what the gates identified. Don't redo work that was correct.
      """
    end
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
