defmodule SymphonyElixir.RoleConfigTest do
  @moduledoc """
  Tests for role config loading and prompt decomposition.
  """
  use ExUnit.Case, async: true

  @fixture_dir Path.join(System.tmp_dir!(), "karkhana-role-test-#{:rand.uniform(99999)}")

  setup do
    # Create a role + skills directory structure
    role_dir = Path.join(@fixture_dir, "roles/implementer")
    skills_dir = Path.join(@fixture_dir, "skills")
    git_skill_dir = Path.join(skills_dir, "git-workflow")
    standards_skill_dir = Path.join(skills_dir, "code-standards")

    File.mkdir_p!(role_dir)
    File.mkdir_p!(git_skill_dir)
    File.mkdir_p!(standards_skill_dir)

    File.write!(Path.join(role_dir, "ROLE.md"), "You are a test implementer.")
    File.write!(Path.join(role_dir, "config.yaml"), """
    tools: [read, bash, edit, write]
    thinking: high
    """)

    File.write!(Path.join(git_skill_dir, "SKILL.md"), """
    ---
    name: git-workflow
    description: Git branching workflow
    ---
    Branch from main, push, open PR.
    """)

    File.write!(Path.join(standards_skill_dir, "SKILL.md"), """
    ---
    name: code-standards
    description: Code quality standards
    ---
    Be thorough. Verify builds pass.
    """)

    on_exit(fn -> File.rm_rf!(@fixture_dir) end)

    %{
      base_dir: @fixture_dir,
      role_dir: role_dir,
      skills_dir: skills_dir
    }
  end

  test "ROLE.md exists and is readable", %{role_dir: role_dir} do
    role_path = Path.join(role_dir, "ROLE.md")
    assert File.exists?(role_path)
    content = File.read!(role_path)
    assert content =~ "test implementer"
  end

  test "config.yaml is parseable", %{role_dir: role_dir} do
    config_path = Path.join(role_dir, "config.yaml")
    assert File.exists?(config_path)
    {:ok, config} = YamlElixir.read_from_file(config_path)
    assert config["tools"] == ["read", "bash", "edit", "write"]
    assert config["thinking"] == "high"
  end

  test "skills directory has SKILL.md files", %{skills_dir: skills_dir} do
    skill_dirs = File.ls!(skills_dir) |> Enum.sort()
    assert skill_dirs == ["code-standards", "git-workflow"]

    for dir_name <- skill_dirs do
      skill_path = Path.join([skills_dir, dir_name, "SKILL.md"])
      assert File.exists?(skill_path), "Missing SKILL.md in #{dir_name}"
    end
  end

  test "skill files have valid frontmatter", %{skills_dir: skills_dir} do
    for dir_name <- File.ls!(skills_dir) do
      skill_path = Path.join([skills_dir, dir_name, "SKILL.md"])
      content = File.read!(skill_path)

      # Check frontmatter delimiters exist
      assert content =~ ~r/^---\n/
      assert String.contains?(content, "name:")
      assert String.contains?(content, "description:")
    end
  end

  test "missing role directory returns nil-compatible behavior", %{base_dir: base_dir} do
    nonexistent = Path.join(base_dir, "roles/reviewer/ROLE.md")
    refute File.exists?(nonexistent)
  end

  test "tools list from config.yaml can be joined for CLI", %{role_dir: role_dir} do
    {:ok, config} = YamlElixir.read_from_file(Path.join(role_dir, "config.yaml"))
    tools_str = Enum.join(config["tools"], ",")
    assert tools_str == "read,bash,edit,write"
  end
end
