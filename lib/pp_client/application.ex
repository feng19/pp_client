defmodule PpClient.Application do
  @moduledoc false
  use Application
  require Logger

  @supervisor PpClient.Supervisor
  @default_endpoint %{
    enable: true,
    type: :socks5,
    ip: {127, 0, 0, 1},
    port: 1080,
    servers: [],
    opts: []
  }

  @impl true
  def start(_type, _args) do
    # Create ETS table for storing port information
    :ets.new(:port_endpoints, [:set, :public, :named_table])

    endpoints =
      if File.exists?("pp_config.exs") do
        {endpoints, _} = Code.eval_file("pp_config.exs")
        endpoints
      else
        IO.puts("NOT found the pp_config.exs")
        []
      end
      |> child_specs()

    children = [
      PpClientWeb.Telemetry,
      {Phoenix.PubSub, name: PpClient.PubSub},
      # Start a worker by calling: PpClient.Worker.start_link(arg)
      # {PpClient.Worker, arg},
      # Start to serve requests, typically the last entry
      PpClientWeb.Endpoint
    ]

    Supervisor.start_link(children ++ endpoints, strategy: :one_for_one, name: @supervisor)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PpClientWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp child_specs(endpoints) do
    endpoints
    |> Stream.map(&Map.merge(@default_endpoint, &1))
    |> Stream.uniq_by(& &1.port)
    |> Stream.map(fn endpoint ->
      # Insert port information into ETS table
      :ets.insert(:port_endpoints, {endpoint.port, endpoint})
      endpoint
    end)
    |> Enum.reduce([], fn
      %{enable: false}, acc ->
        acc

      %{type: type, port: port, servers: []}, acc ->
        Logger.warning("port: #{port} type: #{type} has empty servers, skip this endpoint.")
        acc

      endpoint = %{type: type, port: port, servers: servers}, acc ->
        case Enum.filter(servers, &Map.get(&1, :enable, true)) do
          [] ->
            Logger.warning("port: #{port} type: #{type} has empty servers, skip this endpoint.")
            acc

          servers ->
            [child_spec(%{endpoint | servers: servers}) | acc]
        end
    end)
  end

  defp child_spec(%{type: type, ip: ip, port: port, servers: servers, opts: opts}) do
    handler =
      case type do
        :socks5 -> PpClient.Socks5
        :http -> PpClient.Http
        :auto -> PpClient.AutoDetect
        :http_to_socks5 -> PpClient.HttpToSocks5
      end

    ThousandIsland.child_spec(
      transport_options: [ip: ip],
      port: port,
      handler_module: handler,
      handler_options: %{servers: servers, opts: opts}
    )
    |> Map.put(:id, {ThousandIsland, port})
  end

  def start_endpoint(endpoint) do
    endpoint = Map.merge(@default_endpoint, endpoint)
    port = endpoint.port
    # Update ETS table
    :ets.insert(:port_endpoints, {port, endpoint})
    # Start new child process
    case Supervisor.start_child(@supervisor, child_spec(endpoint)) do
      {:ok, pid} ->
        Logger.info("Started endpoint on port #{port}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start endpoint on port #{port}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def restart_endpoint(endpoint) do
    endpoint = Map.merge(@default_endpoint, endpoint)
    port = endpoint.port
    # Find existing child process ID
    child_id = {ThousandIsland, endpoint.port}

    # First stop existing child process (if it exists)
    case Supervisor.terminate_child(@supervisor, child_id) do
      :ok ->
        Logger.info("Stopped existing endpoint on port #{port}")
        # Delete old child process
        Supervisor.delete_child(@supervisor, child_id)

      {:error, :not_found} ->
        Logger.info("No existing endpoint found on port #{port}")

      {:error, reason} ->
        Logger.error("Failed to terminate child for port #{port}: #{inspect(reason)}")
    end

    # Update ETS table
    :ets.insert(:port_endpoints, {port, endpoint})

    # Start new child process
    case Supervisor.start_child(@supervisor, child_spec(endpoint)) do
      {:ok, pid} ->
        Logger.info("Restarted endpoint on port #{port}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to restart endpoint on port #{port}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
