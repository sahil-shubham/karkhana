import Config

# Runtime configuration for releases.
# This file is evaluated at runtime (not compile time),
# so env vars are read when the release starts.

if config_env() == :prod do
  config :symphony_elixir, SymphonyElixirWeb.Endpoint,
    server: false,
    secret_key_base: System.get_env("SECRET_KEY_BASE") || String.duplicate("k", 64)

  # WORKFLOW.md path — set via env var or defaults to cwd
  if path = System.get_env("KARKHANA_WORKFLOW_PATH") do
    config :symphony_elixir, :workflow_file_path, path
  end

  # Log file path — writable location in the sandbox
  config :symphony_elixir, :log_file,
    System.get_env("KARKHANA_LOG_FILE") || "/tmp/karkhana.log"
end
