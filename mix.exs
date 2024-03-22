defmodule PpClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :pp_client,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps()
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
      {:wind, "~> 0.3"}
    ]
  end
end
