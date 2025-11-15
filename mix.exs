defmodule PpClient.MixProject do
  use Mix.Project

  @app :pp_client

  def project do
    [
      app: @app,
      version: "0.2.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      escript: escript(),
      releases: releases()
    ]
  end

  def application do
    [
      mod: {PpClient.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, release: :prod]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def escript do
    [
      main_module: PpClient,
      emu_args: "+K true -detached -name pp_client@127.0.0.1"
    ]
  end

  defp deps do
    [
      {:tidewave, "~> 0.5", only: [:dev]},
      {:phoenix, "~> 1.8.1"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:wind, "~> 0.3"},
      {:burrito, "~> 1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind pp_client", "esbuild pp_client"],
      "assets.deploy": [
        "tailwind pp_client --minify",
        "esbuild pp_client --minify",
        "phx.digest"
      ],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp releases do
    [
      pp_client: [
        version: {:from_app, @app},
        applications: [pp_client: :permanent],
        include_erts: true,
        include_executables_for: [:unix, :windows],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos: [os: :darwin, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            linux: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64],
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
