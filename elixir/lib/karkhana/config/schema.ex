defmodule Karkhana.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Karkhana.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      # Derived from lifecycle.states when lifecycle is configured.
      # Kept for orchestrator compatibility — active = dispatch states, terminal = terminal states.
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :assignee, :active_states, :terminal_states],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "karkhana_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias Karkhana.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Claude do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "claude")
      field(:provider, :string)
      field(:model, :string)
      field(:max_turns, :integer, default: 50)
      field(:dangerously_skip_permissions, :boolean, default: true)
      field(:allowed_tools, {:array, :string})
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:command, :provider, :model, :max_turns, :dangerously_skip_permissions, :allowed_tools, :turn_timeout_ms, :stall_timeout_ms],
        empty_values: []
      )
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Bhatti do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:url, :string, default: "http://localhost:8080")
      field(:api_key, :string)
      field(:image, :string, default: "minimal")
      field(:cpus, :integer, default: 2)
      field(:memory_mb, :integer, default: 2048)
      field(:disk_mb, :integer, default: 4096)
      field(:volume, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:url, :api_key, :image, :cpus, :memory_mb, :disk_mb, :volume], empty_values: [])
      |> validate_number(:cpus, greater_than: 0)
      |> validate_number(:memory_mb, greater_than: 0)
      |> validate_number(:disk_mb, greater_than: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule Lifecycle do
    @moduledoc """
    Lifecycle configuration mapping Linear workflow states to karkhana behavior.

    Each state has a type:
    - `dispatch` — karkhana dispatches an agent with the configured mode
    - `human_gate` — karkhana pauses, human reviews and advances
    - `terminal` — karkhana destroys the sandbox
    - `idle` — karkhana ignores (human-managed states)

    State configs also carry:
    - `linear_type` — Linear state type for auto-sync (backlog, unstarted, started, completed, canceled)
    - `mode` — mode name for dispatch states
    - `on_complete` — state to transition to when agent + gates succeed
    - `sandbox` — sandbox action at this state (stop, destroy, or nil)
    - `color` — hex color for Linear UI
    - `description` — state description for Linear
    """
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:auto_sync, :boolean, default: true)
      field(:states, :map, default: %{})
    end

    @valid_types ["dispatch", "human_gate", "terminal", "idle"]
    @valid_linear_types ["backlog", "unstarted", "started", "completed", "canceled"]
    @valid_sandbox_actions ["stop", "destroy"]

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:auto_sync, :states], empty_values: [])
      |> validate_states()
    end

    defp validate_states(changeset) do
      validate_change(changeset, :states, fn :states, states ->
        Enum.flat_map(states, fn {name, config} ->
          validate_state_config(name, config)
        end)
      end)
    end

    defp validate_state_config(name, config) when is_map(config) do
      type = config["type"] || config[:type]
      errors = []

      errors =
        if type in @valid_types,
          do: errors,
          else: [{:states, "state '#{name}' has invalid type '#{type}'; must be one of #{inspect(@valid_types)}"}]

      errors =
        case config["linear_type"] || config[:linear_type] do
          nil -> errors
          lt when lt in @valid_linear_types -> errors
          lt -> [{:states, "state '#{name}' has invalid linear_type '#{lt}'"} | errors]
        end

      errors =
        if type == "dispatch" and (config["mode"] || config[:mode]) in [nil, ""] do
          [{:states, "dispatch state '#{name}' must specify a mode"} | errors]
        else
          errors
        end

      errors =
        case config["sandbox"] || config[:sandbox] do
          nil -> errors
          s when s in @valid_sandbox_actions -> errors
          s -> [{:states, "state '#{name}' has invalid sandbox action '#{s}'"} | errors]
        end

      errors
    end

    defp validate_state_config(name, _config) do
      [{:states, "state '#{name}' config must be a map"}]
    end

    @doc "Returns state names where karkhana should dispatch agents."
    @spec dispatch_states(%__MODULE__{}) :: [String.t()]
    def dispatch_states(%__MODULE__{states: states}) do
      states
      |> Enum.filter(fn {_name, config} -> state_type(config) == "dispatch" end)
      |> Enum.map(fn {name, _config} -> name end)
    end

    @doc "Returns state names that are terminal (issue is done/cancelled)."
    @spec terminal_states(%__MODULE__{}) :: [String.t()]
    def terminal_states(%__MODULE__{states: states}) do
      states
      |> Enum.filter(fn {_name, config} -> state_type(config) == "terminal" end)
      |> Enum.map(fn {name, _config} -> name end)
    end

    @doc "Returns state names that are human gates."
    @spec human_gate_states(%__MODULE__{}) :: [String.t()]
    def human_gate_states(%__MODULE__{states: states}) do
      states
      |> Enum.filter(fn {_name, config} -> state_type(config) == "human_gate" end)
      |> Enum.map(fn {name, _config} -> name end)
    end

    @doc "Get the mode name for a given state. Returns nil for non-dispatch states."
    @spec mode_for_state(%__MODULE__{}, String.t()) :: String.t() | nil
    def mode_for_state(%__MODULE__{states: states}, state_name) do
      case Map.get(states, state_name) do
        %{"mode" => mode} -> mode
        _ -> nil
      end
    end

    @doc "Get the on_complete target state for a given state."
    @spec on_complete_state(%__MODULE__{}, String.t()) :: String.t() | nil
    def on_complete_state(%__MODULE__{states: states}, state_name) do
      case Map.get(states, state_name) do
        %{"on_complete" => target} -> target
        _ -> nil
      end
    end

    @doc "Get the sandbox action for a given state (stop, destroy, or nil)."
    @spec sandbox_action(%__MODULE__{}, String.t()) :: String.t() | nil
    def sandbox_action(%__MODULE__{states: states}, state_name) do
      case Map.get(states, state_name) do
        %{"sandbox" => action} -> action
        _ -> nil
      end
    end

    @doc "Get the state config map for a given state name."
    @spec state_config(%__MODULE__{}, String.t()) :: map() | nil
    def state_config(%__MODULE__{states: states}, state_name) do
      Map.get(states, state_name)
    end

    defp state_type(%{"type" => type}), do: type
    defp state_type(_), do: nil
  end

  defmodule Modes do
    @moduledoc """
    Mode configuration: prompt, agent tuning, artifact contracts, gates.
    Stored as a map of mode_name => mode_config.
    """
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:configs, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:configs], empty_values: [])
    end

    @doc "Get mode config by name."
    @spec get(%__MODULE__{}, String.t()) :: map() | nil
    def get(%__MODULE__{configs: configs}, mode_name) do
      Map.get(configs, mode_name)
    end

    @doc "Get the prompt path for a mode."
    @spec prompt_path(%__MODULE__{}, String.t()) :: String.t() | nil
    def prompt_path(%__MODULE__{} = modes, mode_name) do
      case get(modes, mode_name) do
        %{"prompt" => path} -> path
        _ -> nil
      end
    end

    @doc "Get the gate specs for a mode."
    @spec gates(%__MODULE__{}, String.t()) :: [map()]
    def gates(%__MODULE__{} = modes, mode_name) do
      case get(modes, mode_name) do
        %{"gates" => gates} when is_list(gates) -> gates
        _ -> []
      end
    end

    @doc "Get max_turns for a mode, with fallback."
    @spec max_turns(%__MODULE__{}, String.t(), integer()) :: integer()
    def max_turns(%__MODULE__{} = modes, mode_name, default \\ 20) do
      case get(modes, mode_name) do
        %{"agent" => %{"max_turns" => turns}} when is_integer(turns) -> turns
        _ -> default
      end
    end
  end

  defmodule Project do
    @moduledoc "Project metadata: name, language, build/test commands."
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:name, :string)
      field(:language, :string)
      field(:build, :string)
      field(:test, :string)
      field(:repo, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:name, :language, :build, :test, :repo], empty_values: [])
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
    embeds_one(:bhatti, Bhatti, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:lifecycle, Lifecycle, on_replace: :update, defaults_to_struct: true)
    embeds_one(:modes, Modes, on_replace: :update, defaults_to_struct: true)
    embeds_one(:project, Project, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> reshape_modes()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:claude, with: &Claude.changeset/2)
    |> cast_embed(:bhatti, with: &Bhatti.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:lifecycle, with: &Lifecycle.changeset/2)
    |> cast_embed(:project, with: &Project.changeset/2)
    |> cast_embed(:modes, with: &Modes.changeset/2)
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "karkhana_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    bhatti = %{
      settings.bhatti
      | url: resolve_secret_setting(settings.bhatti.url, "http://localhost:8080") || "http://localhost:8080",
        api_key: resolve_secret_setting(settings.bhatti.api_key, System.get_env("BHATTI_API_KEY"))
    }

    # When lifecycle is configured, derive active_states and terminal_states from it
    # so existing orchestrator code continues to work until the lifecycle migration is complete.
    tracker =
      if settings.lifecycle.states != %{} do
        derived_active = Lifecycle.dispatch_states(settings.lifecycle)
        derived_terminal = Lifecycle.terminal_states(settings.lifecycle)
        %{tracker | active_states: derived_active, terminal_states: derived_terminal}
      else
        tracker
      end

    %{settings | tracker: tracker, workspace: workspace, codex: codex, bhatti: bhatti}
  end

  # Modes in workflow.yaml is a map of mode_name => config.
  # Reshape it into %{"modes" => %{"configs" => original_map}} so the
  # Modes embed (which has a single :configs field) can receive it.
  defp reshape_modes(%{"modes" => modes} = config) when is_map(modes) do
    # If it already has a "configs" key, it's already shaped correctly
    if Map.has_key?(modes, "configs") do
      config
    else
      Map.put(config, "modes", %{"configs" => modes})
    end
  end

  defp reshape_modes(config), do: config

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "karkhana_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
