import Config

config :phoenix, :json_library, Jason

config :karkhana, KarkhanaWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: KarkhanaWeb.ErrorHTML, json: KarkhanaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Karkhana.PubSub,
  live_view: [signing_salt: "karkhana-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
