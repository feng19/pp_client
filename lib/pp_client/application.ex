defmodule PpClient.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      if File.exists?("pp_config.exs") do
        {endpoints, _} = Code.eval_file("pp_config.exs")
        endpoints
      else
        IO.puts("NOT found the pp_config.exs")
        []
      end
      |> child_specs()

    opts = [strategy: :one_for_one, name: PpClient.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @default_endpoint %{
    type: :socks5,
    ip: {127, 0, 0, 1},
    port: 1080,
    opts: []
  }

  defp child_specs(endpoints) do
    Enum.map(endpoints, fn endpoint ->
      %{type: type, ip: ip, port: port, servers: servers, opts: opts} =
        Map.merge(@default_endpoint, endpoint)

      handler_module =
        case type do
          :socks5 -> PpClient.Socks5
          :http -> PpClient.Http
          :auto -> PpClient.AutoDetect
          :http_to_socks5 -> PpClient.HttpToSocks5
        end

      handler_options = %{servers: servers, opts: opts}

      {ThousandIsland,
       transport_options: [ip: ip],
       port: port,
       handler_module: handler_module,
       handler_options: handler_options}
    end)
  end
end
