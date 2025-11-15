defmodule PpClient.MixProject do
  use Mix.Project

  @app :pp_client

  def project do
    [
      app: @app,
      version: "0.2.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PpClient.Application, []}
    ]
  end

  def escript do
    [
      main_module: PpClient,
      emu_args: "+K true -detached -name pp_client@127.0.0.1"
    ]
  end

  defp deps do
    [
      {:thousand_island, "~> 1.3"},
      {:wind, "~> 0.3"},
      {:plug_crypto, "~> 2.0"},
      {:burrito, "~> 1.0"}
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
