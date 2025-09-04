defmodule PpClient.HttpToSocks5 do
  @moduledoc false
  use ThousandIsland.Handler
  require Logger
  alias PpClient.{Http, Socks5Client}

  @impl ThousandIsland.Handler
  def handle_connection(_socket, opts) do
    Process.flag(:trap_exit, true)
    {:continue, {:wait_first, opts}}
  end

  @impl ThousandIsland.Handler
  def handle_data(request, _socket, {:wait_first, opts}) do
    case Http.parse_request(request) do
      {:ok, target, next_request} ->
        {:ok, socks5} = Socks5Client.start_link(opts, target, self())
        {:continue, {:connecting, socks5, next_request}}

      _ ->
        {:close, nil}
    end
  end

  def handle_data(data, _socket, {:connected, socks5} = state) do
    Socks5Client.send(socks5, data)
    {:continue, state}
  end

  @impl GenServer
  def handle_cast(:connected, {socket, {:connecting, socks5, next_request}}) do
    if next_request do
      Socks5Client.send(socks5, next_request)
    else
      ThousandIsland.Socket.send(socket, "HTTP/1.1 200 Connection Established\r\n\r\n")
    end

    {:noreply, {socket, {:connected, socks5}}, socket.read_timeout}
  end

  def handle_cast({:send, data}, {socket, state}) do
    ThousandIsland.Socket.send(socket, data)
    {:noreply, {socket, state}, socket.read_timeout}
  end

  def handle_cast(:close, {socket, state}) do
    {:stop, :normal, {socket, state}}
  end

  @impl GenServer
  def handle_info({:EXIT, _, _}, {socket, state}) do
    {:stop, :normal, {socket, state}}
  end
end
