defmodule Karkhana.LogFileTest do
  use ExUnit.Case, async: true

  alias Karkhana.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/karkhana.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/karkhana-logs") == "/tmp/karkhana-logs/log/karkhana.log"
  end
end
