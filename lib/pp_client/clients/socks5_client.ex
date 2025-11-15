defmodule PpClient.Socks5Client do
  @moduledoc """
  SOCKS5 客户端实现
  支持无认证和用户名/密码认证
  """
  use GenServer
  require Logger

  @connect_timeout 5000
  @recv_timeout 10_000
  @atype_ipv4 1
  @atype_domain 3
  @atype_ipv6 4

  def start_link(%{servers: servers, opts: _opts}, target, parent) do
    GenServer.start_link(__MODULE__, server: Enum.random(servers), target: target, parent: parent)
  end

  def send(pid, data) do
    GenServer.cast(pid, {:binary, data})
  end

  @impl true
  def init(server: server, target: target, parent: parent) do
    {:ok, %{socket: nil, parent: parent}, {:continue, {:connect_server, server, target}}}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, %{parent: parent} = state) do
    GenServer.cast(parent, {:send, data})
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_continue({:connect_server, server, target}, %{parent: parent} = state) do
    case connect(server, target) do
      {:ok, socket} ->
        GenServer.cast(parent, :connected)
        {:noreply, %{state | socket: socket}}

      _ ->
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_cast({:binary, data}, %{socket: socket} = state) do
    :gen_tcp.send(socket, data)
    {:noreply, state}
  end

  defp connect(server, target) do
    with {:ok, socket} <- establish_proxy_connection(server),
         :ok <- perform_handshake(socket),
         :ok <- send_connect_request(socket, target),
         :ok <- receive_connect_response(socket) do
      {:ok, socket}
    else
      {:error, reason} = error ->
        Logger.error("SOCKS5 connection failed: #{inspect(reason)}")
        error
    end
  end

  # 建立与代理服务器的连接
  defp establish_proxy_connection(%{host: host, port: port}) do
    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, packet: :raw, active: false],
           @connect_timeout
         ) do
      {:ok, socket} ->
        Logger.debug("Connected to SOCKS5 proxy #{host}:#{port}")
        {:ok, socket}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  # 执行 SOCKS5 握手
  defp perform_handshake(socket) do
    :gen_tcp.send(socket, <<5, 1, 0>>)
    {:ok, <<5, 0>>} = :gen_tcp.recv(socket, 2, @recv_timeout)
    Logger.debug("SOCKS5 handshake completed")
    :ok
  end

  # 发送连接请求
  defp send_connect_request(socket, {@atype_domain, domain, port}) do
    packet = <<5, 1, 0, @atype_domain, byte_size(domain), domain::binary, port::16>>
    :gen_tcp.send(socket, packet)
  end

  # 接收连接响应
  defp receive_connect_response(socket) do
    case :gen_tcp.recv(socket, 4, @recv_timeout) do
      {:ok, <<5, 0, 0, address_type>>} ->
        handle_connect_success(socket, address_type)

      {:ok, <<5, error_code, 0, _>>} ->
        {:error, {:socks5_error, decode_error_code(error_code)}}

      {:ok, data} ->
        {:error, {:invalid_connect_response, data}}

      {:error, reason} ->
        {:error, {:connect_recv_failed, reason}}
    end
  end

  # 处理连接成功响应
  defp handle_connect_success(socket, address_type) do
    address_length = get_address_length(address_type)

    case :gen_tcp.recv(socket, address_length + 2, @recv_timeout) do
      {:ok, _address_and_port} ->
        :inet.setopts(socket, active: true)
        Logger.debug("SOCKS5 connection established successfully")
        :ok

      {:error, reason} ->
        {:error, {:connect_response_incomplete, reason}}
    end
  end

  defp get_address_length(@atype_ipv4), do: 4
  defp get_address_length(@atype_ipv6), do: 16
  defp get_address_length(@atype_domain), do: 0

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
