defmodule PpClient.Http do
  @moduledoc false
  use ThousandIsland.Handler
  require Logger

  @domain 0x03

  @impl ThousandIsland.Handler
  def handle_connection(_socket, opts) do
    Process.flag(:trap_exit, true)
    {:continue, {:wait_first, opts}}
  end

  @impl ThousandIsland.Handler
  def handle_data(request, _socket, {:wait_first, opts}) do
    case parse_request(request) do
      {:ok, target, next_request} ->
        {:ok, ws_client} = PpClient.WSClient.start_link(opts, target, self())
        {:continue, {:connecting, ws_client, next_request}}

      _ ->
        {:close, nil}
    end
  end

  def handle_data(data, _socket, {:connected, ws_client} = state) do
    GenServer.cast(ws_client, {:send, {:binary, data}})
    {:continue, state}
  end

  @impl GenServer
  def handle_cast(:connected, {socket, {:connecting, ws_client, next_request}}) do
    if next_request do
      GenServer.cast(ws_client, {:send, {:binary, next_request}})
    else
      ThousandIsland.Socket.send(socket, "HTTP/1.1 200 Connection Established\r\n\r\n")
    end

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

  defp parse_request(<<"CONNECT ", rest::binary>>) do
    case String.split(rest, "\r\n", parts: 2) do
      [first_line, _rest_lines] ->
        [uri, _version] = String.split(first_line, " ", parts: 2)

        case parse_uri(uri) do
          %URI{host: domain, port: nil} when is_binary(domain) ->
            {:ok, {@domain, domain, 80}, nil}

          %URI{host: domain, port: port} when is_binary(domain) and is_integer(port) ->
            {:ok, {@domain, domain, port}, nil}

          bad_uri ->
            Logger.warning("parse uri: #{inspect(uri)} got bad uri: #{inspect(bad_uri)}")
            {:error, :error_uri}
        end

      _ ->
        {:error, :need_more}
    end
  end

  defp parse_request(request) do
    case String.split(request, "\r\n", parts: 2) do
      [first_line, rest_lines] ->
        [method, uri, version] = String.split(first_line, " ", parts: 3)

        case parse_uri(uri) do
          %URI{host: domain, port: nil, path: path} when is_binary(domain) ->
            next_request =
              <<method::binary, path::binary, " ", version::binary, "\r\n", rest_lines::binary>>

            {:ok, {@domain, domain, 80}, next_request}

          %URI{host: domain, port: port, path: path}
          when is_binary(domain) and is_integer(port) ->
            next_request =
              <<method::binary, path::binary, " ", version::binary, "\r\n", rest_lines::binary>>

            {:ok, {@domain, domain, port}, next_request}

          bad_uri ->
            Logger.warning("parse uri: #{inspect(uri)} got bad uri: #{inspect(bad_uri)}")
            {:error, :error_uri}
        end

      _ ->
        {:error, :need_more}
    end
  end

  defp parse_uri(uri) do
    case URI.parse(uri) do
      %URI{host: nil, port: nil} -> URI.parse("//" <> uri)
      uri -> uri
    end
  end
end
