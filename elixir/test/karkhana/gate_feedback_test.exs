defmodule Karkhana.GateFeedbackTest do
  use ExUnit.Case, async: true

  use Karkhana.TestSupport

  alias Karkhana.PromptBuilder
  alias Karkhana.Linear.Issue

  describe "build_feedback_section/2" do
    test "produces feedback section from gate failures" do
      feedback = [
        %{gate: "plan-quality", output: "Plan missing test criteria for Part 3"},
        %{gate: "plan-exists", output: "No plan found at docs/PLAN-BHA-42.md"}
      ]

      section = PromptBuilder.build_feedback_section(feedback, 2)

      assert section =~ "Feedback from previous attempt (attempt 2)"
      assert section =~ "Gate 'plan-quality' failed:"
      assert section =~ "Plan missing test criteria for Part 3"
      assert section =~ "Gate 'plan-exists' failed:"
      assert section =~ "No plan found"
      assert section =~ "Focus on fixing what the gates identified"
    end

    test "returns empty string for empty feedback" do
      assert PromptBuilder.build_feedback_section([]) == ""
    end

    test "works without attempt number" do
      feedback = [%{gate: "tests", output: "2 tests failed"}]
      section = PromptBuilder.build_feedback_section(feedback)

      assert section =~ "Feedback from previous attempt"
      refute section =~ "(attempt"
      assert section =~ "2 tests failed"
    end
  end

  describe "build_prompt with gate_feedback" do
    test "appends gate feedback to the rendered prompt" do
      issue = %Issue{
        id: "issue-1",
        identifier: "BHA-42",
        title: "Test gate feedback",
        description: "Testing",
        state: "Planning",
        url: "https://example.com",
        labels: []
      }

      feedback = [
        %{gate: "plan-quality", output: "Missing test criteria for Part 3"}
      ]

      prompt = PromptBuilder.build_prompt(issue, gate_feedback: feedback, attempt: 2)

      # Should contain the base prompt
      assert prompt =~ "agent"

      # Should contain the feedback section
      assert prompt =~ "Gate 'plan-quality' failed:"
      assert prompt =~ "Missing test criteria for Part 3"
      assert prompt =~ "attempt 2"
    end

    test "no feedback section when gate_feedback is nil" do
      issue = %Issue{
        id: "issue-2",
        identifier: "BHA-43",
        title: "No feedback",
        description: "Testing",
        state: "Planning",
        url: "https://example.com",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue)

      refute prompt =~ "Feedback from previous attempt"
      refute prompt =~ "Gate"
    end
  end
end
