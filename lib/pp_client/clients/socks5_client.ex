defmodule PpClient.Socks5Client do
  @moduledoc """
  SOCKS5 客户端实现
  支持无认证

  `connect/3` 在调用方进程内完成握手，返回一个已经归调用方所有的 socket，
  之后上下行数据都直接在该 socket 上收发，不再经过中间进程（见 `PpClient.Relay`）。
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

  # 建立与代理服务器的连接
  defp establish_proxy_connection(%{host: host, port: port}) do
    case :gen_tcp.connect(String.to_charlist(host), port, @connect_opts, @connect_timeout) do
      {:ok, socket} ->
        Logger.debug("Connected to SOCKS5 proxy #{host}:#{port}")
        {:ok, socket}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  # 执行 SOCKS5 握手
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

  # 发送连接请求
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

  # 目标里的 atype 由入口协议决定，HTTP 入口一律标成 domain，所以这里按地址本身的
  # 形态重新判断：能解析成 IP 的就按 IP 发，其余按域名发。
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

  # 接收连接响应
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

  # 读掉响应里的 BND.ADDR / BND.PORT，之后 socket 上剩下的就是隧道数据。
  # 少读一个字节就会把回复的残留当成隧道数据，所以这里必须按 atype 精确读完。
  defp discard_bound_address(socket, @atype_ipv4), do: discard(socket, 4 + 2)
  defp discard_bound_address(socket, @atype_ipv6), do: discard(socket, 16 + 2)

  # DOMAINNAME 是变长的，先读掉长度前缀才知道要跳过多少字节
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
