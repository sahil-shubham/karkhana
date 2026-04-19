defmodule Karkhana.Store do
  @moduledoc """
  SQLite-backed persistent store for runs, config events, and issue lifecycle.

  Provides the source of truth for methodology tracking. The orchestrator
  writes here on every run completion and config change. The dashboard
  reads aggregates for methodology metrics.
  """

  use GenServer
  require Logger

  @default_dir ".karkhana"
  @default_filename "store.db"

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec insert_run(map()) :: :ok | {:error, term()}
  def insert_run(run) when is_map(run), do: call({:insert_run, run})

  @spec insert_config_event(map()) :: :ok | {:error, term()}
  def insert_config_event(event) when is_map(event), do: call({:insert_config_event, event})

  @spec insert_issue_event(map()) :: :ok | {:error, term()}
  def insert_issue_event(event) when is_map(event), do: call({:insert_issue_event, event})

  @spec list_runs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_runs(opts \\ []), do: call({:list_runs, opts})

  @spec list_config_events(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_config_events(opts \\ []), do: call({:list_config_events, opts})

  @spec list_issue_events(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_issue_events(issue_identifier) when is_binary(issue_identifier),
    do: call({:list_issue_events, issue_identifier})

  @spec last_session_id(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def last_session_id(issue_identifier) when is_binary(issue_identifier),
    do: call({:last_session_id, issue_identifier})

  @spec run_stats(keyword()) :: {:ok, map()} | {:error, term()}
  def run_stats(opts \\ []), do: call({:run_stats, opts})

  # --- Active sessions (checkpoint/recovery) ---

  @spec upsert_active_session(map()) :: :ok | {:error, term()}
  def upsert_active_session(session) when is_map(session), do: call({:upsert_active_session, session})

  @spec delete_active_session(String.t()) :: :ok | {:error, term()}
  def delete_active_session(issue_id) when is_binary(issue_id), do: call({:delete_active_session, issue_id})

  @spec list_active_sessions() :: {:ok, [map()]} | {:error, term()}
  def list_active_sessions, do: call(:list_active_sessions)

  # --- GenServer ---

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || store_path()
    File.mkdir_p!(Path.dirname(path))

    case Exqlite.Sqlite3.open(path) do
      {:ok, conn} ->
        :ok = create_tables(conn)
        :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
        :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
        {:ok, %{conn: conn, path: path}}

      {:error, reason} ->
        {:stop, {:store_open_failed, path, reason}}
    end
  end

  @impl true
  def handle_call({:insert_run, run}, _from, %{conn: conn} = state) do
    result = do_insert_run(conn, run)
    {:reply, result, state}
  end

  def handle_call({:insert_config_event, event}, _from, %{conn: conn} = state) do
    result = do_insert_config_event(conn, event)
    {:reply, result, state}
  end

  def handle_call({:insert_issue_event, event}, _from, %{conn: conn} = state) do
    result = do_insert_issue_event(conn, event)
    {:reply, result, state}
  end

  def handle_call({:list_runs, opts}, _from, %{conn: conn} = state) do
    result = do_list_runs(conn, opts)
    {:reply, result, state}
  end

  def handle_call({:list_config_events, opts}, _from, %{conn: conn} = state) do
    result = do_list_config_events(conn, opts)
    {:reply, result, state}
  end

  def handle_call({:list_issue_events, issue_identifier}, _from, %{conn: conn} = state) do
    result = do_list_issue_events(conn, issue_identifier)
    {:reply, result, state}
  end

  def handle_call({:last_session_id, issue_identifier}, _from, %{conn: conn} = state) do
    result = do_last_session_id(conn, issue_identifier)
    {:reply, result, state}
  end

  def handle_call({:run_stats, opts}, _from, %{conn: conn} = state) do
    result = do_run_stats(conn, opts)
    {:reply, result, state}
  end

  def handle_call({:upsert_active_session, session}, _from, %{conn: conn} = state) do
    result = do_upsert_active_session(conn, session)
    {:reply, result, state}
  end

  def handle_call({:delete_active_session, issue_id}, _from, %{conn: conn} = state) do
    result = do_delete_active_session(conn, issue_id)
    {:reply, result, state}
  end

  def handle_call(:list_active_sessions, _from, %{conn: conn} = state) do
    result = do_list_active_sessions(conn)
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) do
    Exqlite.Sqlite3.close(conn)
  end

  # --- Schema ---

  defp create_tables(conn) do
    statements = [
      """
      CREATE TABLE IF NOT EXISTS runs (
        id TEXT PRIMARY KEY,
        issue_id TEXT NOT NULL,
        issue_identifier TEXT NOT NULL,
        mode TEXT,
        config_hash TEXT,
        attempt INTEGER NOT NULL DEFAULT 0,
        sandbox_id TEXT,
        sandbox_name TEXT,
        session_id TEXT,
        tokens_input INTEGER NOT NULL DEFAULT 0,
        tokens_output INTEGER NOT NULL DEFAULT 0,
        tokens_cache_read INTEGER NOT NULL DEFAULT 0,
        tokens_cache_write INTEGER NOT NULL DEFAULT 0,
        tokens_total INTEGER NOT NULL DEFAULT 0,
        cost_usd REAL NOT NULL DEFAULT 0.0,
        duration_seconds REAL NOT NULL DEFAULT 0.0,
        outcome TEXT NOT NULL,
        error_message TEXT,
        artifacts_before TEXT,
        artifacts_after TEXT,
        gate TEXT,
        gate_result TEXT,
        gate_output TEXT,
        labels TEXT,
        started_at TEXT NOT NULL,
        ended_at TEXT NOT NULL,
        inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_runs_issue ON runs(issue_identifier)",
      "CREATE INDEX IF NOT EXISTS idx_runs_mode ON runs(mode)",
      "CREATE INDEX IF NOT EXISTS idx_runs_config ON runs(config_hash)",
      "CREATE INDEX IF NOT EXISTS idx_runs_started ON runs(started_at)",
      """
      CREATE TABLE IF NOT EXISTS config_events (
        id TEXT PRIMARY KEY,
        config_hash TEXT NOT NULL,
        previous_hash TEXT,
        changed_files TEXT,
        snapshot TEXT,
        inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_config_hash ON config_events(config_hash)",
      """
      CREATE TABLE IF NOT EXISTS issue_events (
        id TEXT PRIMARY KEY,
        issue_id TEXT NOT NULL,
        issue_identifier TEXT NOT NULL,
        event TEXT NOT NULL,
        mode TEXT,
        config_hash TEXT,
        metadata TEXT,
        inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_issue_events_issue ON issue_events(issue_identifier)",
      "CREATE INDEX IF NOT EXISTS idx_issue_events_event ON issue_events(event)",
      """
      CREATE TABLE IF NOT EXISTS active_sessions (
        issue_id TEXT PRIMARY KEY,
        issue_identifier TEXT NOT NULL,
        issue_json TEXT NOT NULL,
        sandbox_id TEXT NOT NULL,
        sandbox_name TEXT NOT NULL,
        mode TEXT,
        output_file TEXT,
        lines_seen INTEGER DEFAULT 0,
        session_id TEXT,
        tokens_input INTEGER DEFAULT 0,
        tokens_output INTEGER DEFAULT 0,
        tokens_total INTEGER DEFAULT 0,
        tokens_cache_read INTEGER DEFAULT 0,
        cost_usd REAL DEFAULT 0.0,
        attempt INTEGER DEFAULT 0,
        started_at TEXT NOT NULL,
        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
      )
      """
    ]

    Enum.each(statements, &(:ok = Exqlite.Sqlite3.execute(conn, &1)))
    :ok
  end

  # --- Inserts ---

  defp do_insert_run(conn, run) do
    id = gen_id()

    sql = """
    INSERT INTO runs (id, issue_id, issue_identifier, mode, config_hash, attempt,
      sandbox_id, sandbox_name, session_id,
      tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, tokens_total,
      cost_usd, duration_seconds, outcome, error_message,
      artifacts_before, artifacts_after, gate, gate_result, gate_output,
      labels, started_at, ended_at)
    VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26)
    """

    tokens = Map.get(run, :tokens, %{})

    params = [
      id,
      run[:issue_id],
      run[:issue_identifier],
      run[:mode],
      run[:config_hash],
      run[:attempt] || 0,
      run[:sandbox_id],
      run[:sandbox_name],
      run[:session_id],
      tokens[:input] || 0,
      tokens[:output] || 0,
      tokens[:cache_read] || 0,
      tokens[:cache_write] || 0,
      tokens[:total] || 0,
      run[:cost_usd] || 0.0,
      run[:duration_seconds] || 0.0,
      to_string(run[:outcome] || "unknown"),
      run[:error_message],
      encode_json(run[:artifacts_before]),
      encode_json(run[:artifacts_after]),
      run[:gate],
      run[:gate_result] && to_string(run[:gate_result]),
      run[:gate_output],
      encode_json(run[:labels]),
      to_iso8601(run[:started_at]),
      to_iso8601(run[:ended_at])
    ]

    exec_insert(conn, sql, params)
  end

  defp do_insert_config_event(conn, event) do
    id = gen_id()

    sql = """
    INSERT INTO config_events (id, config_hash, previous_hash, changed_files, snapshot)
    VALUES (?1, ?2, ?3, ?4, ?5)
    """

    params = [
      id,
      event[:config_hash],
      event[:previous_hash],
      encode_json(event[:changed_files]),
      encode_json(event[:snapshot])
    ]

    exec_insert(conn, sql, params)
  end

  defp do_insert_issue_event(conn, event) do
    id = gen_id()

    sql = """
    INSERT INTO issue_events (id, issue_id, issue_identifier, event, mode, config_hash, metadata)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    """

    params = [
      id,
      event[:issue_id],
      event[:issue_identifier],
      to_string(event[:event]),
      event[:mode],
      event[:config_hash],
      encode_json(event[:metadata])
    ]

    exec_insert(conn, sql, params)
  end

  # --- Queries ---

  defp do_list_runs(conn, opts) do
    limit = Keyword.get(opts, :limit, 100)
    mode = Keyword.get(opts, :mode)
    issue = Keyword.get(opts, :issue_identifier)

    {where, params} = build_run_filters(mode, issue)

    sql = "SELECT * FROM runs #{where} ORDER BY started_at DESC LIMIT ?#{length(params) + 1}"
    query_all(conn, sql, params ++ [limit], &row_to_run/2)
  end

  defp do_list_config_events(conn, opts) do
    limit = Keyword.get(opts, :limit, 50)
    sql = "SELECT * FROM config_events ORDER BY inserted_at DESC LIMIT ?1"
    query_all(conn, sql, [limit], &row_to_config_event/2)
  end

  defp do_list_issue_events(conn, issue_identifier) do
    sql = "SELECT * FROM issue_events WHERE issue_identifier = ?1 ORDER BY inserted_at ASC"
    query_all(conn, sql, [issue_identifier], &row_to_issue_event/2)
  end

  defp do_last_session_id(conn, issue_identifier) do
    sql = """
    SELECT session_id FROM runs
    WHERE issue_identifier = ?1 AND session_id IS NOT NULL AND outcome = 'success'
    ORDER BY ended_at DESC LIMIT 1
    """

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, [issue_identifier])

      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, [session_id]} when is_binary(session_id) -> {:ok, session_id}
        _ -> {:ok, nil}
      end
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp do_run_stats(conn, _opts) do
    with {:ok, total} <- query_one_value(conn, "SELECT COUNT(*) FROM runs", []),
         {:ok, total_cost} <- query_one_value(conn, "SELECT COALESCE(SUM(cost_usd), 0.0) FROM runs", []),
         {:ok, by_mode} <- query_kv(conn, "SELECT mode, COUNT(*) FROM runs GROUP BY mode", []),
         {:ok, by_outcome} <- query_kv(conn, "SELECT outcome, COUNT(*) FROM runs GROUP BY outcome", []),
         {:ok, gate_stats} <- query_gate_stats(conn),
         {:ok, cost_by_mode} <- query_kv(conn, "SELECT mode, ROUND(AVG(cost_usd), 4) FROM runs GROUP BY mode", []) do
      {:ok,
       %{
         total: total,
         total_cost: total_cost || 0.0,
         by_mode: by_mode,
         by_outcome: by_outcome,
         gate_pass_rate: gate_stats,
         avg_cost_by_mode: cost_by_mode
       }}
    end
  end

  defp query_gate_stats(conn) do
    sql = """
    SELECT gate,
      ROUND(1.0 * SUM(CASE WHEN gate_result = 'pass' THEN 1 ELSE 0 END) / COUNT(*), 2)
    FROM runs WHERE gate IS NOT NULL GROUP BY gate
    """

    query_kv(conn, sql, [])
  end

  # --- SQL helpers ---

  defp exec_insert(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)

      case Exqlite.Sqlite3.step(conn, stmt) do
        :done -> :ok
        {:error, reason} -> {:error, reason}
      end
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp query_all(conn, sql, params, row_mapper) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      {:ok, columns} = Exqlite.Sqlite3.columns(conn, stmt)
      rows = fetch_rows(conn, stmt, columns, row_mapper, [])
      {:ok, rows}
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  rescue
    e -> {:error, e}
  end

  defp fetch_rows(conn, stmt, columns, row_mapper, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, values} ->
        row = row_mapper.(columns, values)
        fetch_rows(conn, stmt, columns, row_mapper, [row | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  defp query_one_value(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)

      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, [value]} -> {:ok, value}
        :done -> {:ok, 0}
      end
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp query_kv(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      rows = fetch_kv_rows(conn, stmt, [])
      {:ok, Map.new(rows)}
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp fetch_kv_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [k, v]} -> fetch_kv_rows(conn, stmt, [{k, v} | acc])
      :done -> acc
    end
  end

  defp build_run_filters(nil, nil), do: {"", []}

  defp build_run_filters(mode, nil) when is_binary(mode),
    do: {"WHERE mode = ?1", [mode]}

  defp build_run_filters(nil, issue) when is_binary(issue),
    do: {"WHERE issue_identifier = ?1", [issue]}

  defp build_run_filters(mode, issue) when is_binary(mode) and is_binary(issue),
    do: {"WHERE mode = ?1 AND issue_identifier = ?2", [mode, issue]}

  # --- Row mappers ---

  defp row_to_run(columns, values) do
    map = Enum.zip(columns, values) |> Map.new()

    %{
      id: map["id"],
      issue_id: map["issue_id"],
      issue_identifier: map["issue_identifier"],
      mode: map["mode"],
      config_hash: map["config_hash"],
      attempt: map["attempt"],
      sandbox_id: map["sandbox_id"],
      sandbox_name: map["sandbox_name"],
      session_id: map["session_id"],
      tokens: %{
        input: map["tokens_input"],
        output: map["tokens_output"],
        cache_read: map["tokens_cache_read"],
        cache_write: map["tokens_cache_write"],
        total: map["tokens_total"]
      },
      cost_usd: map["cost_usd"],
      duration_seconds: map["duration_seconds"],
      outcome: map["outcome"],
      error_message: map["error_message"],
      artifacts_before: decode_json(map["artifacts_before"]),
      artifacts_after: decode_json(map["artifacts_after"]),
      gate: map["gate"],
      gate_result: map["gate_result"],
      gate_output: map["gate_output"],
      labels: decode_json(map["labels"]),
      started_at: map["started_at"],
      ended_at: map["ended_at"],
      inserted_at: map["inserted_at"]
    }
  end

  defp row_to_config_event(columns, values) do
    map = Enum.zip(columns, values) |> Map.new()

    %{
      id: map["id"],
      config_hash: map["config_hash"],
      previous_hash: map["previous_hash"],
      changed_files: decode_json(map["changed_files"]),
      snapshot: decode_json(map["snapshot"]),
      inserted_at: map["inserted_at"]
    }
  end

  defp row_to_issue_event(columns, values) do
    map = Enum.zip(columns, values) |> Map.new()

    %{
      id: map["id"],
      issue_id: map["issue_id"],
      issue_identifier: map["issue_identifier"],
      event: map["event"],
      mode: map["mode"],
      config_hash: map["config_hash"],
      metadata: decode_json(map["metadata"]),
      inserted_at: map["inserted_at"]
    }
  end

  # --- Active sessions ---

  defp do_upsert_active_session(conn, session) do
    sql = """
    INSERT OR REPLACE INTO active_sessions
      (issue_id, issue_identifier, issue_json, sandbox_id, sandbox_name,
       mode, output_file, lines_seen, session_id,
       tokens_input, tokens_output, tokens_total, tokens_cache_read,
       cost_usd, attempt, started_at, updated_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
    """

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    params = [
      session[:issue_id],
      session[:issue_identifier],
      session[:issue_json] || "{}",
      session[:sandbox_id],
      session[:sandbox_name] || "",
      session[:mode],
      session[:output_file],
      session[:lines_seen] || 0,
      session[:session_id],
      session[:tokens_input] || 0,
      session[:tokens_output] || 0,
      session[:tokens_total] || 0,
      session[:tokens_cache_read] || 0,
      session[:cost_usd] || 0.0,
      session[:attempt] || 0,
      format_datetime(session[:started_at]),
      now
    ]

    exec_insert(conn, sql, params)
  end

  defp do_delete_active_session(conn, issue_id) do
    exec_insert(conn, "DELETE FROM active_sessions WHERE issue_id = ?1", [issue_id])
  end

  defp do_list_active_sessions(conn) do
    query_all(conn, "SELECT * FROM active_sessions ORDER BY started_at", [], &row_to_map/2)
  end

  defp row_to_map(columns, values) do
    columns
    |> Enum.zip(values)
    |> Map.new(fn {col, val} -> {String.to_atom(col), val} end)
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(dt) when is_binary(dt), do: dt
  defp format_datetime(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  # --- Helpers ---

  defp call(request) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :store_not_running}
      _pid -> GenServer.call(__MODULE__, request, 10_000)
    end
  end

  defp gen_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp encode_json(nil), do: nil
  defp encode_json(value), do: Jason.encode!(value)

  defp decode_json(nil), do: nil

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso8601(value) when is_binary(value), do: value
  defp to_iso8601(_), do: DateTime.to_iso8601(DateTime.utc_now())

  defp store_path do
    Application.get_env(:karkhana, :store_path) ||
      Path.join([System.user_home!(), @default_dir, @default_filename])
  end
end
