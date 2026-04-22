defmodule Karkhana.MixProject do
  use Mix.Project

  def project do
    [
      app: :karkhana,
      version: "0.7.15",
      elixir: "~> 1.18",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          Karkhana.Config,
          Karkhana.Linear.Client,
          Karkhana.SpecsCheck,
          Karkhana.Orchestrator,
          Karkhana.Orchestrator.State,
          Karkhana.AgentRunner,
          Karkhana.CLI,
          Karkhana.Codex.AppServer,
          Karkhana.Codex.DynamicTool,
          Karkhana.HttpServer,
          Karkhana.StatusDashboard,
          Karkhana.LogFile,
          Karkhana.Workspace,
          KarkhanaWeb.DashboardLive,
          KarkhanaWeb.Endpoint,
          KarkhanaWeb.ErrorHTML,
          KarkhanaWeb.ErrorJSON,
          KarkhanaWeb.Layouts,
          KarkhanaWeb.ObservabilityApiController,
          KarkhanaWeb.Presenter,
          KarkhanaWeb.StaticAssetController,
          KarkhanaWeb.StaticAssets,
          KarkhanaWeb.Router,
          KarkhanaWeb.Router.Helpers
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      releases: releases(),
      escript: escript(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Karkhana.Application, []},
      extra_applications: [:logger, :inets, :ssl, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:ecto, "~> 3.13"},
      {:exqlite, "~> 0.27"},
      {:mint_web_socket, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["specs.check", "credo --strict"]
    ]
  end

  defp releases do
    [
      karkhana: [
        include_erts: true,
        strip_beams: true,
        cookie: "karkhana-release-cookie"
      ]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: Karkhana.CLI,
      name: "karkhana",
      path: "bin/karkhana"
    ]
  end
end
