defmodule PpClient.AutoSwitchClient do
  @moduledoc """
  Auto Switch Client

  Picks a route for a target and hands the caller back a connection handle:

    * `{:tcp, socket}` — a raw socket the caller now owns, so `send/2` writes to
      it directly and the caller reads the upstream out of its own mailbox.
    * `{WSClient, pid}` — the WebSocket route, which has to stay behind a process
      because framing and the Mint connection live in it.
  """
  require Logger
  alias PpClient.{Cache, DirectClient, ProfileManager, Redact, Socks5Client, WSClient}

  @type conn :: {:tcp, :gen_tcp.socket()} | {WSClient, pid()}

  def start_link(target, opts, parent \\ self()) do
    case profile_route(opts, target) do
      {:ok, route} ->
        do_start_link(route, target, parent)

      {:error, reason} = error ->
        Logger.warning("No route for target: #{inspect(target)}, reason: #{inspect(reason)}")
        error
    end
  end

  defp profile_route(opts, target) do
    case Keyword.get(opts, :profile) do
      nil ->
        {:ok, route(target)}

      name ->
        case ProfileManager.get_profile(name) do
          {:ok, %{enabled: true, type: :direct}} -> {:ok, :direct}
          {:ok, %{enabled: true, servers: servers}} -> profile_server_route(name, servers)
          {:ok, %{enabled: false}} -> {:error, {:profile_disabled, name}}
          {:error, :not_found} -> {:error, {:profile_not_found, name}}
        end
    end
  end

  defp profile_server_route(name, servers) do
    case pick_server(servers) do
      nil -> {:error, {:no_enabled_server, name}}
      route -> {:ok, route}
    end
  end

  defp do_start_link(:direct, target, parent) do
    with {:ok, socket} <- DirectClient.connect(target, parent) do
      {:ok, {:tcp, socket}}
    end
  end

  defp do_start_link({:ws, setting}, target, parent) do
    with {:ok, ws_client} <- WSClient.start_link(target, setting, parent) do
      {:ok, {WSClient, ws_client}}
    end
  end

  defp do_start_link({:socks5, setting}, target, parent) do
    with {:ok, socket} <- Socks5Client.connect(target, setting, parent) do
      {:ok, {:tcp, socket}}
    end
  end

  defp do_start_link(route, target, _parent) do
    # A route carries the server's raw setting, credential included.
    Logger.warning("Unsupported route: #{inspect(redact(route))}, target: #{inspect(target)}")
    {:error, {:unsupported_route, route}}
  end

  defp redact({client_type, setting}) when is_map(setting),
    do: {client_type, Redact.setting(setting)}

  defp redact(route), do: route

  def route({_type, host, _port}), do: route(host)

  def route(host) do
    Cache.conditions()
    |> Enum.find_value(fn
      {:all, type, servers} ->
        condition_route(type, servers)

      {regex, type, servers} ->
        if Regex.match?(regex, host) do
          condition_route(type, servers)
        end
    end)
    |> Kernel.||(:direct)
  end

  # A condition pointing at a direct profile carries no servers, and a remote one
  # without usable servers is skipped so the next condition gets a chance.
  defp condition_route(:direct, _servers), do: :direct
  defp condition_route(_type, servers), do: pick_server(servers)

  # nil when the profile has no server left to pick, disabled ones excluded.
  defp pick_server(servers) do
    case Enum.filter(servers, & &1.enable) do
      [] ->
        nil

      servers ->
        server = Enum.random(servers)
        {server.client_type, server.opts |> Map.new() |> Map.put(:type, server.type)}
    end
  end

  @spec send(conn(), iodata()) :: :ok | {:error, term()}
  def send({:tcp, socket}, data), do: :gen_tcp.send(socket, data)
  def send({WSClient, ws_client}, data), do: WSClient.send(ws_client, data)

  @doc """
  Hands the client socket to the connection so it can write downstream data
  itself.

  A no-op for raw sockets: the caller already owns both ends there. Must be
  called only after the caller has written whatever protocol greeting it owes the
  client, so the socket is never written by two processes at once.
  """
  @spec attach(conn(), ThousandIsland.Socket.t()) :: :ok
  def attach({:tcp, _upstream}, _socket), do: :ok
  def attach({WSClient, ws_client}, socket), do: WSClient.attach(ws_client, socket)
end
