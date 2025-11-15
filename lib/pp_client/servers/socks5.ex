defmodule PpClient.Socks5 do
  @moduledoc false
  use ThousandIsland.Handler
  alias PpClient.WSClient

  @ipv4 0x01
  @ipv6 0x04
  @domain 0x03

  @impl ThousandIsland.Handler
  def handle_connection(_socket, opts) do
    Process.flag(:trap_exit, true)
    {:continue, {:wait_first, opts}}
  end

  @impl ThousandIsland.Handler
  def handle_data(<<5, _Nmethods, _Bin::binary>>, socket, {:wait_first, opts}) do
    ThousandIsland.Socket.send(socket, <<5, 0>>)
    {:continue, {:wait_second, opts}}
  end

  def handle_data(<<5, 1, _Rsv, address_type, rest::binary>>, _socket, {:wait_second, opts}) do
    target = parse_target(address_type, rest)
    {:ok, ws_client} = WSClient.start_link(opts, target, self())
    {:continue, {:connecting, ws_client}}
  end

  def handle_data(data, _socket, {:connected, ws_client} = state) do
    WSClient.send(ws_client, data)
    {:continue, state}
  end

  @impl GenServer
  def handle_cast(:connected, {socket, {:connecting, ws_client}}) do
    ThousandIsland.Socket.send(socket, <<5, 0, 0, 1, 0, 0, 0, 0, 0, 0>>)
    {:noreply, {socket, {:connected, ws_client}}, socket.read_timeout}
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

  defp parse_target(@ipv4, <<a, b, c, d, port::16, _::binary>>) do
    {@ipv4, "#{a}.#{b}.#{c}.#{d}", port}
  end

  defp parse_target(
         @ipv6,
         <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16, port::16, _::binary>>
       ) do
    {@ipv6, {a, b, c, d, e, f, g, h} |> :inet.ntoa() |> to_string(), port}
  end

  defp parse_target(@domain, <<len, domain::binary-size(len), port::16, _::binary>>) do
    {@domain, domain, port}
  end
end
