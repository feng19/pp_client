defmodule PpClient.HttpToSocks5 do
  @moduledoc false
  use ThousandIsland.Handler
  use PpClient.Relay
  require Logger
  alias PpClient.{AutoSwitchClient, Http, ProfileManager, Relay, Socks5Client}

  @impl ThousandIsland.Handler
  def handle_connection(_socket, opts) do
    Process.flag(:trap_exit, true)
    {:continue, {:wait_first, opts}}
  end

  @impl ThousandIsland.Handler
  def handle_data(request, _socket, {:wait_first, opts}) do
    case Http.parse_request(request) do
      {:ok, target, next_request} ->
        with {:ok, setting} <- socks5_setting(opts),
             {:ok, socket} <- Socks5Client.connect(target, setting, self()) do
          {:continue, {:connecting, {:tcp, socket}, next_request}}
        else
          {:error, reason} ->
            Logger.warning("http_to_socks5 has no socks5 upstream: #{inspect(reason)}")
            {:close, nil}
        end

      _ ->
        {:close, nil}
    end
  end

  def handle_data(data, _socket, {:connected, socks5} = state) do
    Relay.forward(socks5, data, state)
  end

  @impl GenServer
  def handle_cast(:connected, {socket, {:connecting, socks5, next_request}}) do
    if next_request do
      AutoSwitchClient.send(socks5, next_request)
    else
      ThousandIsland.Socket.send(socket, "HTTP/1.1 200 Connection Established\r\n\r\n")
    end

    {:noreply, {Relay.touch(socket), {:connected, socks5}}}
  end

  def handle_cast(:close, {socket, state}) do
    {:stop, :normal, {socket, state}}
  end

  # The endpoint options are `[profile: name]`, so the profile has to be resolved
  # to one of its socks5 servers before Socks5Client can connect.
  defp socks5_setting(opts) do
    case Keyword.get(opts, :profile) do
      nil ->
        {:error, :no_profile}

      name ->
        with {:ok, %{enabled: true, servers: servers}} <- ProfileManager.get_profile(name),
             [_ | _] = servers <-
               Enum.filter(servers, &(&1.enable and &1.client_type == :socks5)) do
          server = Enum.random(servers)
          {:ok, server.opts |> Map.new() |> Map.put(:type, server.type)}
        else
          [] -> {:error, {:no_socks5_server, name}}
          {:ok, %{enabled: false}} -> {:error, {:profile_disabled, name}}
          {:error, :not_found} -> {:error, {:profile_not_found, name}}
        end
    end
  end
end
