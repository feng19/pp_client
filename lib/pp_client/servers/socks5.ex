defmodule PpClient.Socks5 do
  @moduledoc false
  use ThousandIsland.Handler
  use PpClient.Relay
  require Logger
  alias PpClient.{AutoSwitchClient, Relay}

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

  def handle_data(<<5, 1, _Rsv, address_type, rest::binary>>, socket, {:wait_second, opts}) do
    case parse_target(address_type, rest) do
      nil ->
        # 0x08: address type not supported
        ThousandIsland.Socket.send(socket, <<5, 8, 0, 1, 0, 0, 0, 0, 0, 0>>)
        {:close, nil}

      target ->
        case AutoSwitchClient.start_link(target, opts) do
          {:ok, client} ->
            {:continue, {:connecting, client}}

          {:error, _reason} ->
            # 0x01: general SOCKS server failure
            ThousandIsland.Socket.send(socket, <<5, 1, 0, 1, 0, 0, 0, 0, 0, 0>>)
            {:close, nil}
        end
    end
  end

  def handle_data(data, _socket, {:connected, client} = state) do
    Relay.forward(client, data, state)
  end

  # Anything else (SOCKS4 clients, unsupported commands, truncated requests):
  # drop the connection instead of crashing the handler.
  def handle_data(data, _socket, _state) do
    Logger.warning("socks5 got unsupported request: #{inspect(data, limit: 16)}")
    {:close, nil}
  end

  @impl GenServer
  def handle_cast(:connected, {socket, {:connecting, client}}) do
    ThousandIsland.Socket.send(socket, <<5, 0, 0, 1, 0, 0, 0, 0, 0, 0>>)
    # Success reply is on the wire, so the tunnel can take over writing downstream.
    AutoSwitchClient.attach(client, socket)
    {:noreply, {Relay.touch(socket), {:connected, client}}}
  end

  def handle_cast(:close, {socket, state}) do
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

  defp parse_target(_address_type, _rest), do: nil
end
