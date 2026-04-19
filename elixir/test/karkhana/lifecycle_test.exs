defmodule Karkhana.LifecycleTest do
  use ExUnit.Case, async: true

  alias Karkhana.Config.Schema
  alias Karkhana.Config.Schema.{Lifecycle, Modes}

  describe "Lifecycle schema" do
    test "parses lifecycle states from config" do
      config =
        base_config(%{
          "lifecycle" => %{
            "auto_sync" => true,
            "states" => %{
              "Todo" => %{"type" => "dispatch", "linear_type" => "unstarted", "mode" => "planning", "on_complete" => "Plan Review", "color" => "#e2e2e2"},
              "Planning" => %{"type" => "dispatch", "linear_type" => "started", "mode" => "planning", "on_complete" => "Plan Review", "color" => "#f2c94c"},
              "Plan Review" => %{"type" => "human_gate", "linear_type" => "started", "sandbox" => "stop", "color" => "#f2994a"},
              "Implementing" => %{"type" => "dispatch", "linear_type" => "started", "mode" => "implementation", "on_complete" => "In Review", "color" => "#4ea7fc"},
              "In Review" => %{"type" => "human_gate", "linear_type" => "completed", "sandbox" => "stop", "color" => "#f2994a"},
              "Done" => %{"type" => "terminal", "linear_type" => "completed", "sandbox" => "destroy", "color" => "#5e6ad2"},
              "Cancelled" => %{"type" => "terminal", "linear_type" => "canceled", "sandbox" => "destroy", "color" => "#95a2b3"},
              "Backlog" => %{"type" => "idle", "linear_type" => "backlog", "color" => "#bec2c8"}
            }
          }
        })

      assert {:ok, settings} = Schema.parse(config)
      lifecycle = settings.lifecycle

      assert lifecycle.auto_sync == true
      assert map_size(lifecycle.states) == 8
    end

    test "dispatch_states returns only dispatch type states" do
      lifecycle = build_lifecycle()
      dispatch = Lifecycle.dispatch_states(lifecycle)

      assert "Todo" in dispatch
      assert "Planning" in dispatch
      assert "Implementing" in dispatch
      refute "Plan Review" in dispatch
      refute "Done" in dispatch
      refute "Backlog" in dispatch
    end

    test "terminal_states returns only terminal type states" do
      lifecycle = build_lifecycle()
      terminal = Lifecycle.terminal_states(lifecycle)

      assert "Done" in terminal
      assert "Cancelled" in terminal
      refute "Planning" in terminal
      refute "In Review" in terminal
    end

    test "human_gate_states returns only human_gate type states" do
      lifecycle = build_lifecycle()
      gates = Lifecycle.human_gate_states(lifecycle)

      assert "Plan Review" in gates
      assert "In Review" in gates
      refute "Planning" in gates
      refute "Done" in gates
    end

    test "mode_for_state returns mode for dispatch states" do
      lifecycle = build_lifecycle()

      assert Lifecycle.mode_for_state(lifecycle, "Todo") == "planning"
      assert Lifecycle.mode_for_state(lifecycle, "Planning") == "planning"
      assert Lifecycle.mode_for_state(lifecycle, "Implementing") == "implementation"
      assert Lifecycle.mode_for_state(lifecycle, "Plan Review") == nil
      assert Lifecycle.mode_for_state(lifecycle, "Done") == nil
    end

    test "on_complete_state returns the target state" do
      lifecycle = build_lifecycle()

      assert Lifecycle.on_complete_state(lifecycle, "Todo") == "Plan Review"
      assert Lifecycle.on_complete_state(lifecycle, "Planning") == "Plan Review"
      assert Lifecycle.on_complete_state(lifecycle, "Implementing") == "In Review"
      assert Lifecycle.on_complete_state(lifecycle, "Plan Review") == nil
    end

    test "sandbox_action returns action for states that have one" do
      lifecycle = build_lifecycle()

      assert Lifecycle.sandbox_action(lifecycle, "Plan Review") == "stop"
      assert Lifecycle.sandbox_action(lifecycle, "In Review") == "stop"
      assert Lifecycle.sandbox_action(lifecycle, "Done") == "destroy"
      assert Lifecycle.sandbox_action(lifecycle, "Planning") == nil
    end

    test "derives active_states from lifecycle dispatch states" do
      config =
        base_config(%{
          "lifecycle" => %{
            "states" => %{
              "Todo" => %{"type" => "dispatch", "linear_type" => "unstarted", "mode" => "planning", "on_complete" => "Plan Review", "color" => "#e2e2e2"},
              "Planning" => %{"type" => "dispatch", "linear_type" => "started", "mode" => "planning", "on_complete" => "Plan Review", "color" => "#f2c94c"},
              "Done" => %{"type" => "terminal", "linear_type" => "completed", "color" => "#5e6ad2"}
            }
          }
        })

      assert {:ok, settings} = Schema.parse(config)
      assert "Todo" in settings.tracker.active_states
      assert "Planning" in settings.tracker.active_states
      refute "Done" in settings.tracker.active_states
    end

    test "derives terminal_states from lifecycle terminal states" do
      config =
        base_config(%{
          "lifecycle" => %{
            "states" => %{
              "Todo" => %{"type" => "dispatch", "linear_type" => "unstarted", "mode" => "planning", "on_complete" => "Review", "color" => "#e2e2e2"},
              "Done" => %{"type" => "terminal", "linear_type" => "completed", "color" => "#5e6ad2"},
              "Cancelled" => %{"type" => "terminal", "linear_type" => "canceled", "color" => "#95a2b3"}
            }
          }
        })

      assert {:ok, settings} = Schema.parse(config)
      assert "Done" in settings.tracker.terminal_states
      assert "Cancelled" in settings.tracker.terminal_states
      refute "Todo" in settings.tracker.terminal_states
    end

    test "validates dispatch state must have a mode" do
      config =
        base_config(%{
          "lifecycle" => %{
            "states" => %{
              "Bad" => %{"type" => "dispatch", "linear_type" => "started", "color" => "#ff0000"}
            }
          }
        })

      assert {:error, {:invalid_workflow_config, msg}} = Schema.parse(config)
      assert msg =~ "dispatch state 'Bad' must specify a mode"
    end

    test "validates state type must be valid" do
      config =
        base_config(%{
          "lifecycle" => %{
            "states" => %{
              "Bad" => %{"type" => "bogus", "linear_type" => "started", "color" => "#ff0000"}
            }
          }
        })

      assert {:error, {:invalid_workflow_config, msg}} = Schema.parse(config)
      assert msg =~ "invalid type"
    end
  end

  describe "Modes schema" do
    test "parses modes from config" do
      config =
        base_config(%{
          "modes" => %{
            "planning" => %{
              "prompt" => "modes/planning.md",
              "agent" => %{"max_turns" => 8, "thinking_budget" => "high"},
              "gates" => [
                %{"name" => "plan-exists", "check" => "artifact_exists", "artifact" => "plan"}
              ]
            },
            "implementation" => %{
              "prompt" => "modes/implementation.md",
              "gates" => [
                %{"name" => "builds", "check" => "command", "command" => "go build ./..."}
              ]
            }
          }
        })

      assert {:ok, settings} = Schema.parse(config)
      modes = settings.modes

      assert Modes.prompt_path(modes, "planning") == "modes/planning.md"
      assert Modes.prompt_path(modes, "implementation") == "modes/implementation.md"
      assert Modes.max_turns(modes, "planning") == 8
      # default
      assert Modes.max_turns(modes, "implementation") == 20
      assert length(Modes.gates(modes, "planning")) == 1
      assert length(Modes.gates(modes, "implementation")) == 1
    end

    test "missing mode returns nil" do
      config = base_config(%{})
      assert {:ok, settings} = Schema.parse(config)

      assert Modes.get(settings.modes, "nonexistent") == nil
      assert Modes.prompt_path(settings.modes, "nonexistent") == nil
      assert Modes.gates(settings.modes, "nonexistent") == []
    end
  end

  describe "Project schema" do
    test "parses project metadata" do
      config =
        base_config(%{
          "project" => %{
            "name" => "bhatti",
            "language" => "go",
            "build" => "go build ./...",
            "test" => "go test ./...",
            "repo" => "github.com/sahil-shubham/bhatti"
          }
        })

      assert {:ok, settings} = Schema.parse(config)
      assert settings.project.name == "bhatti"
      assert settings.project.language == "go"
      assert settings.project.build == "go build ./..."
      assert settings.project.test == "go test ./..."
    end
  end

  # --- helpers ---

  defp base_config(overrides) do
    Map.merge(
      %{
        "tracker" => %{
          "kind" => "linear",
          "api_key" => "test-key",
          "project_slug" => "test-project"
        }
      },
      overrides
    )
  end

  defp build_lifecycle do
    %Lifecycle{
      auto_sync: true,
      states: %{
        "Backlog" => %{"type" => "idle", "linear_type" => "backlog", "color" => "#bec2c8"},
        "Todo" => %{"type" => "dispatch", "linear_type" => "unstarted", "mode" => "planning", "on_complete" => "Plan Review", "color" => "#e2e2e2"},
        "Planning" => %{"type" => "dispatch", "linear_type" => "started", "mode" => "planning", "on_complete" => "Plan Review", "color" => "#f2c94c"},
        "Plan Review" => %{"type" => "human_gate", "linear_type" => "started", "sandbox" => "stop", "color" => "#f2994a"},
        "Implementing" => %{"type" => "dispatch", "linear_type" => "started", "mode" => "implementation", "on_complete" => "In Review", "color" => "#4ea7fc"},
        "In Review" => %{"type" => "human_gate", "linear_type" => "completed", "sandbox" => "stop", "color" => "#f2994a"},
        "Done" => %{"type" => "terminal", "linear_type" => "completed", "sandbox" => "destroy", "color" => "#5e6ad2"},
        "Cancelled" => %{"type" => "terminal", "linear_type" => "canceled", "sandbox" => "destroy", "color" => "#95a2b3"}
      }
    }
  end
end
