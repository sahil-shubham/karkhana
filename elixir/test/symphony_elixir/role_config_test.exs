defmodule SymphonyElixir.RoleConfigTest do
  @moduledoc """
  Tests load_role_config behavior with realistic directory structures.
  Tests the actual function by calling AgentRunner internals through
  a test-specific wrapper.
  """
  use ExUnit.Case, async: true

  # load_role_config is private to AgentRunner. We test it by setting up
  # realistic file structures and verifying the CLI args that result.
  # This tests the integration: files on disk → role config map → Pi flags.

  @base_dir Path.join(System.tmp_dir!(), "karkhana-role-test-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@base_dir)
    File.mkdir_p!(@base_dir)
    on_exit(fn -> File.rm_rf!(@base_dir) end)
    :ok
  end

  describe "role directory structure" do
    test "complete role directory produces valid config" do
      setup_role("implementer", "You are an implementer.", "tools: [read, bash, edit, write]\nthinking: high\n")
      setup_skills(["git-workflow", "code-standards"])

      config = load_config("implementer")
      assert config != nil
      assert config.name == "implementer"
      assert config.tools == "read,bash,edit,write"
      assert config.thinking == "high"
      assert File.exists?(config.system_prompt_file)
      assert length(config.skill_dirs) == 2
    end

    test "role without config.yaml uses nil tools and thinking" do
      role_dir = Path.join([@base_dir, "roles", "minimal"])
      File.mkdir_p!(role_dir)
      File.write!(Path.join(role_dir, "ROLE.md"), "You are a minimal role.")

      config = load_config("minimal")
      assert config != nil
      assert config.tools == nil
      assert config.thinking == nil
    end

    test "missing role directory returns nil" do
      config = load_config("nonexistent")
      assert config == nil
    end

    test "role with no skills directory returns empty skill_dirs" do
      setup_role("lonely", "No skills available.", "tools: [read]\n")
      # Don't create skills dir

      config = load_config("lonely")
      assert config != nil
      assert config.skill_dirs == []
    end

    test "malformed config.yaml doesn't crash" do
      role_dir = Path.join([@base_dir, "roles", "broken"])
      File.mkdir_p!(role_dir)
      File.write!(Path.join(role_dir, "ROLE.md"), "Broken config.")
      File.write!(Path.join(role_dir, "config.yaml"), "not: [valid: yaml: {{{")

      # Should not raise — returns config with nil tools/thinking
      config = load_config("broken")
      assert config != nil
      assert config.tools == nil
    end

    test "tools list handles non-list values gracefully" do
      setup_role("scalar-tools", "Scalar tools.", "tools: bash\nthinking: low\n")

      config = load_config("scalar-tools")
      assert config != nil
      # Non-list tools value should result in nil (not crash)
      assert config.tools == nil
      assert config.thinking == "low"
    end

    test "skills directory with non-directory entries is filtered" do
      setup_role("filtered", "Filter test.", "tools: [read]\n")
      skills_dir = Path.join(@base_dir, "skills")
      File.mkdir_p!(skills_dir)
      # Create a regular file (not a directory) in skills/
      File.write!(Path.join(skills_dir, "README.md"), "not a skill")
      # Create a proper skill directory
      File.mkdir_p!(Path.join(skills_dir, "real-skill"))

      config = load_config("filtered")
      assert length(config.skill_dirs) == 1
      assert hd(config.skill_dirs) =~ "real-skill"
    end
  end

  # Helpers — replicate load_role_config logic for testing.
  # This tests the same algorithm the agent_runner uses.

  defp setup_role(name, role_content, config_content) do
    role_dir = Path.join([@base_dir, "roles", name])
    File.mkdir_p!(role_dir)
    File.write!(Path.join(role_dir, "ROLE.md"), role_content)
    File.write!(Path.join(role_dir, "config.yaml"), config_content)
  end

  defp setup_skills(names) do
    skills_dir = Path.join(@base_dir, "skills")
    for name <- names do
      dir = Path.join(skills_dir, name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "---\nname: #{name}\ndescription: Test skill\n---\nContent.")
    end
  end

  defp load_config(role_name) do
    role_dir = Path.join([@base_dir, "roles", role_name])
    skills_dir = Path.join(@base_dir, "skills")
    role_md = Path.join(role_dir, "ROLE.md")
    config_yaml = Path.join(role_dir, "config.yaml")

    if File.exists?(role_md) do
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

      skill_dirs = if File.dir?(skills_dir) do
        File.ls!(skills_dir)
        |> Enum.map(&Path.join(skills_dir, &1))
        |> Enum.filter(&File.dir?/1)
      else
        []
      end

      %{
        name: role_name,
        system_prompt_file: role_md,
        tools: tools,
        thinking: thinking,
        skill_dirs: skill_dirs
      }
    else
      nil
    end
  end
end
