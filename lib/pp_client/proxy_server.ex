defmodule PpClient.ProxyServer do
  @moduledoc """
  Proxy Server struct

  - type: "exps", enable: boolean, opts: [uri: "wss://ws.example.com/ws", encrypt_type: :none | :once, encrypt_key: encrypt_key]
  - type: "cf-workers", enable: boolean, opts: [uri: "wss://ws.example.com", password: password]
  - type: "socks5", enable: boolean, opts: [host: "127.0.0.1", port: 1088]
  """

  defstruct [:type, :client_type, :enable, :opts]

  @type client_type() :: :direct | :ws | :socks5

  @type t :: %__MODULE__{
          type: String.t(),
          client_type: client_type(),
          enable: boolean(),
          opts: map()
        }

  @doc """
  创建 EXPS 类型代理服务器

  ## 参数
    - uri: WebSocket 连接地址
    - encrypt_type: 加密类型 (:none | :once)
    - encrypt_key: 加密密钥

  ## 示例
      iex> PpClient.ProxyServer.exps("wss://ws.example.com/ws", :none, nil)
      %PpClient.ProxyServer{
        type: "exps",
        enable: true,
        opts: %{uri: "wss://ws.example.com/ws", encrypt_type: :none, encrypt_key: nil}
      }
  """
  def exps(uri, encrypt_type \\ :none, encrypt_key \\ nil) do
    %__MODULE__{
      type: "exps",
      client_type: :ws,
      enable: true,
      opts: %{
        uri: uri,
        encrypt_type: encrypt_type,
        encrypt_key: encrypt_key
      }
    }
  end

  @doc """
  创建 Cloudflare Workers 类型代理服务器

  ## 参数
    - uri: WebSocket 连接地址
    - password: 认证密码

  ## 示例
      iex> PpClient.ProxyServer.cf_workers("wss://ws.example.com", "secret")
      %PpClient.ProxyServer{
        type: "cf-workers",
        enable: true,
        opts: %{uri: "wss://ws.example.com", password: "secret"}
      }
  """
  def cf_workers(uri, password) do
    %__MODULE__{
      type: "cf-workers",
      client_type: :ws,
      enable: true,
      opts: %{
        uri: uri,
        password: password
      }
    }
  end

  @doc """
  创建 SOCKS5 类型代理服务器

  ## 参数
    - host: 代理服务器地址
    - port: 代理服务器端口

  ## 示例
      iex> PpClient.ProxyServer.socks5("127.0.0.1", 1088)
      %PpClient.ProxyServer{
        type: "socks5",
        enable: true,
        opts: %{host: "127.0.0.1", port: 1088}
      }
  """
  def socks5(host, port) do
    %__MODULE__{
      type: "socks5",
      client_type: :socks5,
      enable: true,
      opts: %{
        host: host,
        port: port
      }
    }
  end

  def enable(server), do: %{server | enable: true}
  def disable(server), do: %{server | enable: false}

  @doc """
  验证代理服务器配置
  """
  def validate(%__MODULE__{type: type, opts: opts} = server) do
    case type do
      "exps" ->
        validate_exps(opts)

      "cf-workers" ->
        validate_cf_workers(opts)

      "socks5" ->
        validate_socks5(opts)

      _ ->
        {:error, "Unknown proxy server type: #{type}"}
    end
    |> case do
      :ok -> {:ok, server}
      error -> error
    end
  end

  defp validate_exps(%{uri: uri, encrypt_type: encrypt_type}) when is_binary(uri) do
    if encrypt_type in [:none, :once] do
      :ok
    else
      {:error, "Invalid encrypt_type for exps: #{inspect(encrypt_type)}"}
    end
  end

  defp validate_exps(_), do: {:error, "Invalid exps configuration"}

  defp validate_cf_workers(%{uri: uri, password: password})
       when is_binary(uri) and is_binary(password) do
    :ok
  end

  defp validate_cf_workers(_), do: {:error, "Invalid cf-workers configuration"}

  defp validate_socks5(%{host: host, port: port})
       when is_binary(host) and is_integer(port) and port > 0 and port <= 65535 do
    :ok
  end

  defp validate_socks5(_), do: {:error, "Invalid socks5 configuration"}
end
