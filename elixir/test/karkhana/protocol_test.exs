defmodule Karkhana.ProtocolTest do
  use ExUnit.Case, async: true

  alias Karkhana.Protocol
  alias Karkhana.Linear.Issue

  @test_dir Path.join(System.tmp_dir!(), "karkhana-protocol-test")

  setup do
    test_id = System.unique_integer([:positive])
    project = Path.join(@test_dir, "project-#{test_id}")
    karkhana = Path.join(project, ".karkhana")
    modes_dir = Path.join(karkhana, "modes")
    gates_dir = Path.join(karkhana, "gates")

    File.mkdir_p!(modes_dir)
    File.mkdir_p!(gates_dir)

    on_exit(fn -> File.rm_rf!(project) end)

    %{project: project, karkhana: karkhana, modes_dir: modes_dir, gates_dir: gates_dir}
  end

  defp write_workflow(karkhana, _modes \\ nil) do
    yaml = """
    modes:
      - match:
          label: qa
        prompt: modes/qa.md
      - match:
          label: debug
        prompt: modes/debugging.md
      - match:
          has_artifact: plan
        prompt: modes/implementation.md
        gate: gates/tests-pass.sh
      - match: default
        prompt: modes/planning.md
        gate: gates/plan-ready.sh

    artifacts:
      plan:
        paths:
          - /workspace/docs/PLAN.md
      branch:
        check: "git branch --list feature | grep -q ."
    """

    File.write!(Path.join(karkhana, "workflow.yaml"), yaml)
  end

  defp write_mode_prompt(modes_dir, name, content) do
    File.write!(Path.join(modes_dir, name), content)
  end

  defp make_issue(labels \\ []) do
    %Issue{
      id: "issue-1",
      identifier: "TST-1",
      title: "Test issue",
      labels: labels
    }
  end

  describe "load/1" do
    test "loads .karkhana/ directory", %{project: project, karkhana: karkhana, modes_dir: modes_dir} do
      write_workflow(karkhana)
      write_mode_prompt(modes_dir, "planning.md", "planning prompt")

      assert {:ok, %Protocol{} = protocol} = Protocol.load(project)
      assert length(protocol.modes) == 4
      assert is_binary(protocol.config_hash)
      assert protocol.dir == Path.join(project, ".karkhana")
    end

    test "returns error when no .karkhana/ exists" do
      assert {:error, :not_found} = Protocol.load("/nonexistent/path")
    end
  end

  describe "resolve_mode/3" do
    test "label match takes priority", %{project: project, karkhana: karkhana, modes_dir: modes_dir} do
      write_workflow(karkhana)
      write_mode_prompt(modes_dir, "qa.md", "QA prompt {{ issue.identifier }}")

      {:ok, protocol} = Protocol.load(project)
      mode = Protocol.resolve_mode(protocol, make_issue(["qa"]))

      assert mode.name == "qa"
      assert mode.prompt_content == "QA prompt {{ issue.identifier }}"
    end

    test "debug label resolves to debugging mode", %{project: project, karkhana: karkhana, modes_dir: modes_dir} do
      write_workflow(karkhana)
      write_mode_prompt(modes_dir, "debugging.md", "debug prompt")

      {:ok, protocol} = Protocol.load(project)
      mode = Protocol.resolve_mode(protocol, make_issue(["debug"]))

      assert mode.name == "debug"
      assert mode.prompt_content == "debug prompt"
    end

    test "artifact check resolves mode", %{project: project, karkhana: karkhana, modes_dir: modes_dir} do
      write_workflow(karkhana)
      write_mode_prompt(modes_dir, "implementation.md", "impl prompt")

      {:ok, protocol} = Protocol.load(project)

      # Artifact checker: plan exists (PLAN.md path check returns true)
      checker = fn cmd -> String.contains?(cmd, "PLAN.md") end
      mode = Protocol.resolve_mode(protocol, make_issue(), checker)

      assert mode.name == "implementation"
      assert mode.gate == "gates/tests-pass.sh"
    end

    test "falls back to default when nothing matches", %{project: project, karkhana: karkhana, modes_dir: modes_dir} do
      write_workflow(karkhana)
      write_mode_prompt(modes_dir, "planning.md", "planning prompt")

      {:ok, protocol} = Protocol.load(project)

      # No label match, no artifacts exist → falls to default rule
      checker = fn _cmd -> false end
      mode = Protocol.resolve_mode(protocol, make_issue(), checker)

      # Default rule points to modes/planning.md → name derived from filename
      assert mode.name == "planning"
      assert mode.prompt_content == "planning prompt"
      assert mode.gate == "gates/plan-ready.sh"
    end

    test "falls back to default without artifact checker", %{project: project, karkhana: karkhana, modes_dir: modes_dir} do
      write_workflow(karkhana)
      write_mode_prompt(modes_dir, "planning.md", "plan")

      {:ok, protocol} = Protocol.load(project)
      mode = Protocol.resolve_mode(protocol, make_issue())

      # No checker → no artifacts exist → default rule
      assert mode.name == "planning"
    end
  end

  describe "check_artifacts/2" do
    test "returns list of existing artifacts", %{project: project, karkhana: karkhana} do
      write_workflow(karkhana)
      {:ok, protocol} = Protocol.load(project)

      checker = fn cmd ->
        cond do
          String.contains?(cmd, "PLAN.md") -> true
          String.contains?(cmd, "git branch") -> false
          true -> false
        end
      end

      assert ["plan"] = Protocol.check_artifacts(protocol, checker)
    end

    test "returns empty when nothing exists", %{project: project, karkhana: karkhana} do
      write_workflow(karkhana)
      {:ok, protocol} = Protocol.load(project)

      assert [] = Protocol.check_artifacts(protocol, fn _cmd -> false end)
    end
  end

  describe "gate resolution" do
    test "mode with gate returns gate path", %{project: project, karkhana: karkhana, modes_dir: modes_dir, gates_dir: gates_dir} do
      write_workflow(karkhana)
      write_mode_prompt(modes_dir, "planning.md", "plan")
      File.write!(Path.join(gates_dir, "plan-ready.sh"), "#!/bin/bash\necho PASS\nexit 0")

      {:ok, protocol} = Protocol.load(project)
      mode = Protocol.resolve_mode(protocol, make_issue())

      assert mode.gate == "gates/plan-ready.sh"

      # The gate script file exists and is readable
      gate_path = Path.join(protocol.dir, mode.gate)
      assert {:ok, script} = File.read(gate_path)
      assert script =~ "PASS"
    end

    test "mode without gate returns nil gate", %{project: project, karkhana: karkhana, modes_dir: modes_dir} do
      write_workflow(karkhana)
      write_mode_prompt(modes_dir, "qa.md", "qa")

      {:ok, protocol} = Protocol.load(project)
      mode = Protocol.resolve_mode(protocol, make_issue(["qa"]))

      assert mode.gate == nil
    end
  end

  describe "prompt builder integration" do
    test "mode prompt renders with issue variables", %{project: project, karkhana: karkhana, modes_dir: modes_dir} do
      write_workflow(karkhana)
      write_mode_prompt(modes_dir, "qa.md", "QA for {{ issue.identifier }} mode={{ mode }}")

      {:ok, protocol} = Protocol.load(project)
      mode = Protocol.resolve_mode(protocol, make_issue(["qa"]))

      result = Karkhana.PromptBuilder.build_prompt(
        make_issue(["qa"]),
        mode: mode.name,
        mode_prompt: mode.prompt_content
      )

      assert result =~ "QA for TST-1"
      assert result =~ "mode=qa"
    end

    test "mode variable available in standard WORKFLOW.md templates" do
      # Level 1: labels drive mode via Liquid conditionals
      result = Karkhana.PromptBuilder.build_prompt(
        make_issue(["qa"]),
        mode: "qa"
      )

      # The default WORKFLOW.md template doesn't use {{ mode }} but
      # the variable is available. This test just verifies no crash.
      assert is_binary(result)
    end
  end
end
