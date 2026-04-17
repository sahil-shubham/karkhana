defmodule KarkhanaWeb.CacheBodyReader do
  @moduledoc """
  Custom body reader for Plug.Parsers that caches the raw body
  in conn.assigns[:raw_body] for HMAC signature verification.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}

      {:more, partial, conn} ->
        {:more, partial, Plug.Conn.assign(conn, :raw_body, partial)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
