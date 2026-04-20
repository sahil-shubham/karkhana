defmodule KarkhanaWeb.Formatters do
  @moduledoc "Shared formatting helpers for dashboard views."

  @spec format_cost(number() | nil) :: String.t()
  def format_cost(nil), do: "0.00"
  def format_cost(cost) when is_float(cost), do: :erlang.float_to_binary(cost, decimals: 2)
  def format_cost(cost) when is_integer(cost), do: :erlang.float_to_binary(cost / 1, decimals: 2)
  def format_cost(_), do: "0.00"

  @spec format_runtime(DateTime.t() | String.t() | nil, DateTime.t()) :: String.t()
  def format_runtime(%DateTime{} = started, %DateTime{} = now) do
    format_duration(max(DateTime.diff(now, started, :second), 0))
  end

  def format_runtime(started, now) when is_binary(started) do
    case DateTime.from_iso8601(started) do
      {:ok, dt, _} -> format_runtime(dt, now)
      _ -> "—"
    end
  end

  def format_runtime(_, _), do: "—"

  @spec format_duration(number() | nil) :: String.t()
  def format_duration(nil), do: "—"

  def format_duration(secs) when is_number(secs) do
    m = div(trunc(secs), 60)
    s = rem(trunc(secs), 60)
    if m > 0, do: "#{m}m #{s}s", else: "#{s}s"
  end

  @spec format_int(integer() | nil) :: String.t()
  def format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  def format_int(_), do: "0"

  @spec format_time(DateTime.t() | nil) :: String.t()
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  def format_time(_), do: ""

  @spec short_id(String.t() | nil) :: String.t()
  def short_id(nil), do: "—"
  def short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 12)
  def short_id(id), do: id
end
