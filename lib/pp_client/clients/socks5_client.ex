defmodule PpClient.Socks5Client do
  @moduledoc """
  SOCKS5 client implementation.
  Supports the no-auth method only.

  `connect/3` performs the handshake inside the calling process and returns a socket
  already owned by that caller. Traffic then flows directly over that socket in both
  directions, with no relay process in between (see `PpClient.Relay`).
  """
  require Logger
  alias PpClient.Relay

  @connect_timeout 10_000
  @recv_timeout 30_000
  @connect_opts [:binary, packet: :raw, active: false, nodelay: true]
  @atype_ipv4 1
  @atype_domain 3
  @atype_ipv6 4

  @spec connect(tuple(), map() | keyword(), pid()) ::
          {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect(target, %{servers: servers}, owner) do
    server = Enum.random(servers)
    connect(target, [{:type, server.type} | server.opts], owner)
  end

  def connect(target, setting, owner) when is_list(setting) do
    connect(target, Map.new(setting), owner)
  end

  def connect(target, setting, owner) when is_map(setting) do
    case establish_proxy_connection(setting) do
      {:ok, socket} ->
        negotiate(socket, target, owner)

      {:error, reason} = error ->
        Logger.error("SOCKS5 connection failed: #{inspect(reason)}")
        error
    end
  end

  defp negotiate(socket, target, owner) do
    with :ok <- perform_handshake(socket),
         :ok <- send_connect_request(socket, target),
         :ok <- receive_connect_response(socket) do
      Logger.debug("SOCKS5 connection established successfully")
      Relay.attach(socket, owner)
    else
      {:error, reason} = error ->
        :gen_tcp.close(socket)
        Logger.error("SOCKS5 connection failed: #{inspect(reason)}")
        error
    end
  end

  # Open the connection to the proxy server
  defp establish_proxy_connection(%{host: host, port: port}) do
    case :gen_tcp.connect(String.to_charlist(host), port, @connect_opts, @connect_timeout) do
      {:ok, socket} ->
        Logger.debug("Connected to SOCKS5 proxy #{host}:#{port}")
        {:ok, socket}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  # Perform the SOCKS5 handshake
  defp perform_handshake(socket) do
    with :ok <- :gen_tcp.send(socket, <<5, 1, 0>>),
         {:ok, <<5, 0>>} <- :gen_tcp.recv(socket, 2, @recv_timeout) do
      Logger.debug("SOCKS5 handshake completed")
      :ok
    else
      {:ok, response} -> {:error, {:unsupported_auth_method, response}}
      {:error, reason} -> {:error, {:handshake_failed, reason}}
    end
  end

  # Send the connect request
  defp send_connect_request(socket, {_atype, address, port})
       when is_binary(address) and is_integer(port) do
    case encode_address(address) do
      {:ok, encoded} -> :gen_tcp.send(socket, <<5, 1, 0, encoded::binary, port::16>>)
      {:error, _reason} = error -> error
    end
  end

  defp send_connect_request(_socket, target) do
    {:error, {:unsupported_target, target}}
  end

  # The atype on the target comes from the inbound protocol, and the HTTP entry point
  # always labels it a domain. So decide again from the address itself: send it as an IP
  # when it parses as one, otherwise as a domain name.
  defp encode_address(address) do
    case :inet.parse_address(to_charlist(address)) do
      {:ok, {a, b, c, d}} ->
        {:ok, <<@atype_ipv4, a, b, c, d>>}

      {:ok, {a, b, c, d, e, f, g, h}} ->
        {:ok, <<@atype_ipv6, a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>}

      {:error, :einval} ->
        encode_domain(address)
    end
  end

  defp encode_domain(domain) when byte_size(domain) in 1..255 do
    {:ok, <<@atype_domain, byte_size(domain), domain::binary>>}
  end

  defp encode_domain(domain), do: {:error, {:invalid_domain, domain}}

  # Receive the connect reply
  defp receive_connect_response(socket) do
    case :gen_tcp.recv(socket, 4, @recv_timeout) do
      {:ok, <<5, 0, 0, address_type>>} ->
        discard_bound_address(socket, address_type)

      {:ok, <<5, error_code, 0, _>>} ->
        {:error, {:socks5_error, decode_error_code(error_code)}}

      {:ok, data} ->
        {:error, {:invalid_connect_response, data}}

      {:error, reason} ->
        {:error, {:connect_recv_failed, reason}}
    end
  end

  # Consume BND.ADDR / BND.PORT from the reply so that whatever is left on the socket is
  # tunnel data. Reading one byte too few would feed leftovers of the reply into the
  # tunnel, so this has to consume exactly what the atype implies.
  defp discard_bound_address(socket, @atype_ipv4), do: discard(socket, 4 + 2)
  defp discard_bound_address(socket, @atype_ipv6), do: discard(socket, 16 + 2)

  # DOMAINNAME is variable length: read the length prefix first to know how much to skip
  defp discard_bound_address(socket, @atype_domain) do
    case :gen_tcp.recv(socket, 1, @recv_timeout) do
      {:ok, <<length>>} -> discard(socket, length + 2)
      {:error, reason} -> {:error, {:connect_response_incomplete, reason}}
    end
  end

  defp discard_bound_address(_socket, address_type) do
    {:error, {:unsupported_bound_address_type, address_type}}
  end

  defp discard(socket, length) do
    case :gen_tcp.recv(socket, length, @recv_timeout) do
      {:ok, _address_and_port} -> :ok
      {:error, reason} -> {:error, {:connect_response_incomplete, reason}}
    end
  end

  def decode_error_code(0), do: :succeeded
  def decode_error_code(1), do: :general_failure
  def decode_error_code(2), do: :connection_not_allowed
  def decode_error_code(3), do: :network_unreachable
  def decode_error_code(4), do: :host_unreachable
  def decode_error_code(5), do: :connection_refused
  def decode_error_code(6), do: :ttl_expired
  def decode_error_code(7), do: :command_not_supported
  def decode_error_code(8), do: :address_type_not_supported
  def decode_error_code(code), do: {:unknown_error, code}
end
