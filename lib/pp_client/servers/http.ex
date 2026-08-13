defmodule PpClient.Http do
  @moduledoc false
  use ThousandIsland.Handler
  use PpClient.Relay
  require Logger
  alias PpClient.{AutoSwitchClient, Relay}

  @domain 0x03

  @impl ThousandIsland.Handler
  def handle_connection(_socket, opts) do
    Process.flag(:trap_exit, true)
    {:continue, {:wait_first, opts}}
  end

  @impl ThousandIsland.Handler
  def handle_data(request, _socket, {:wait_first, opts}) do
    with {:ok, target, next_request} <- parse_request(request),
         {:ok, client} <- AutoSwitchClient.start_link(target, opts) do
      {:continue, {:connecting, client, next_request}}
    else
      _ -> {:close, nil}
    end
  end

  def handle_data(data, _socket, {:connected, client} = state) do
    Relay.forward(client, data, state)
  end

  @impl GenServer
  def handle_cast(:connected, {socket, {:connecting, client, next_request}}) do
    if next_request do
      AutoSwitchClient.send(client, next_request)
    else
      ThousandIsland.Socket.send(socket, "HTTP/1.1 200 Connection Established\r\n\r\n")
    end

    # Greeting is on the wire, so the tunnel can take over writing downstream.
    AutoSwitchClient.attach(client, socket)
    {:noreply, {Relay.touch(socket), {:connected, client}}}
  end

  def handle_cast(:close, {socket, state}) do
    {:stop, :normal, {socket, state}}
  end

  def parse_request(<<"CONNECT ", rest::binary>>) do
    case request_line(rest) do
      {:ok, [uri | _version], _rest_lines} ->
        with {:ok, domain, port} <- parse_authority(uri), do: {:ok, {@domain, domain, port}, nil}

      {:ok, tokens, _rest_lines} ->
        Logger.warning("http got bad CONNECT line: #{inspect(tokens)}")
        {:error, :error_request_line}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parse_request(request) do
    case request_line(request) do
      {:ok, [method, uri, version], rest_lines} ->
        rewrite_request(method, uri, version, rest_lines)

      {:ok, tokens, _rest_lines} ->
        Logger.warning("http got bad request line: #{inspect(tokens)}")
        {:error, :error_request_line}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The request line is split off and tokenised in one place so the trailing CR
  # never leaks into the version token.
  defp request_line(request) do
    case String.split(request, "\n", parts: 2, trim: true) do
      [first_line, rest_lines] ->
        tokens =
          first_line
          |> String.trim_trailing("\r")
          |> String.split(" ", parts: 3, trim: true)

        {:ok, tokens, rest_lines}

      _ ->
        {:error, :need_more}
    end
  end

  # The client sends an absolute URI; upstream servers expect the origin form, so
  # the authority is dropped and path/query put back. The `Host` header already in
  # `rest_lines` carries the authority.
  defp rewrite_request(method, uri, version, rest_lines) do
    case parse_uri(uri) do
      %URI{host: domain} = parsed when is_binary(domain) ->
        next_request =
          IO.iodata_to_binary([
            method,
            " ",
            request_target(parsed),
            " ",
            version,
            "\r\n",
            rest_lines
          ])

        {:ok, {@domain, domain, parsed.port || 80}, next_request}

      bad_uri ->
        Logger.warning("parse uri: #{inspect(uri)} got bad uri: #{inspect(bad_uri)}")
        {:error, :error_uri}
    end
  end

  defp parse_authority(uri) do
    case parse_uri(uri) do
      %URI{host: domain, port: port} when is_binary(domain) ->
        {:ok, domain, port || 80}

      bad_uri ->
        Logger.warning("parse uri: #{inspect(uri)} got bad uri: #{inspect(bad_uri)}")
        {:error, :error_uri}
    end
  end

  # An authority-only URI parses to an empty path, and the query is kept apart
  # from it — both have to be restored for a valid origin form.
  defp request_target(%URI{path: path, query: nil}), do: path || "/"
  defp request_target(%URI{path: path, query: query}), do: [path || "/", "?", query]

  defp parse_uri(uri) do
    uri
    |> String.trim()
    |> URI.parse()
    |> case do
      %URI{host: nil, port: nil} -> URI.parse("//" <> uri)
      uri -> uri
    end
  end
end
