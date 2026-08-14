defmodule PpClient.ProxyServer do
  @moduledoc """
  Proxy Server struct

  - type: "exps", enable: boolean, opts: [uri: "wss://ws.example.com/ws", encrypt_type: :none | :once, encrypt_key: encrypt_key]
  - type: "cf-workers", enable: boolean, opts: [uri: "wss://ws.example.com", password: password]
  - type: "socks5", enable: boolean, opts: [host: "127.0.0.1", port: 1088]

  `name` is the identity a profile refers to. It is the key servers are stored
  under in `PpClient.ServerManager`, and the key of the `servers:` entry in
  `pp.exs` — a profile lists names, never server definitions.
  """

  @enforce_keys [:name, :type, :opts]
  defstruct name: nil, type: nil, client_type: nil, enable: true, opts: nil

  @type client_type() :: :direct | :ws | :socks5

  @type t :: %__MODULE__{
          name: String.t(),
          type: String.t(),
          client_type: client_type(),
          enable: boolean(),
          opts: map()
        }

  @doc """
  Builds an EXPS proxy server.

  ## Parameters
    - name: the name profiles refer to
    - uri: WebSocket endpoint
    - encrypt_type: encryption type (:none | :once)
    - encrypt_key: encryption key

  ## Examples
      iex> PpClient.ProxyServer.exps("my_exps", "wss://ws.example.com/ws", :none, nil)
      %PpClient.ProxyServer{
        name: "my_exps",
        type: "exps",
        enable: true,
        opts: %{uri: "wss://ws.example.com/ws", encrypt_type: :none, encrypt_key: nil}
      }
  """
  # No defaults: with them this would still define exps/3, so every pre-name call
  # site would keep compiling with every argument shifted one to the right.
  def exps(name, uri, encrypt_type, encrypt_key) do
    %__MODULE__{
      name: name,
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
  Builds a Cloudflare Workers proxy server.

  ## Parameters
    - name: the name profiles refer to
    - uri: WebSocket endpoint
    - password: authentication password

  ## Examples
      iex> PpClient.ProxyServer.cf_workers("my_cf", "wss://ws.example.com", "secret")
      %PpClient.ProxyServer{
        name: "my_cf",
        type: "cf-workers",
        enable: true,
        opts: %{uri: "wss://ws.example.com", password: "secret"}
      }
  """
  def cf_workers(name, uri, password) do
    %__MODULE__{
      name: name,
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
  Builds a SOCKS5 proxy server.

  ## Parameters
    - name: the name profiles refer to
    - host: proxy server address
    - port: proxy server port

  ## Examples
      iex> PpClient.ProxyServer.socks5("local_socks", "127.0.0.1", 1088)
      %PpClient.ProxyServer{
        name: "local_socks",
        type: "socks5",
        enable: true,
        opts: %{host: "127.0.0.1", port: 1088}
      }
  """
  def socks5(name, host, port) do
    %__MODULE__{
      name: name,
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

  def new(opts) do
    struct!(__MODULE__, opts) |> validate!()
  end

  def validate!(server) do
    case validate(server) do
      {:ok, server} -> server
      {:error, reason} -> raise reason
    end
  end

  # A nameless server cannot be referred to by a profile, so it is not a server
  # this application can route through — reject it before looking at the type.
  def validate(%__MODULE__{name: name}) when not is_binary(name) or name == "" do
    {:error, "Server name is required"}
  end

  def validate(%__MODULE__{type: type} = server) do
    case type do
      "exps" -> validate_exps(server)
      "cf-workers" -> validate_cf_workers(server)
      "socks5" -> validate_socks5(server)
      _ -> {:error, "Unknown server type: #{type}"}
    end
  end

  defp validate_exps(%__MODULE__{opts: opts} = server) do
    cond do
      not ws_uri?(opts[:uri]) -> {:error, "Invalid exps uri: #{inspect(opts[:uri])}"}
      opts[:encrypt_type] not in [:none, :once] -> {:error, "Invalid exps opts"}
      true -> {:ok, %{server | client_type: :ws}}
    end
  end

  defp validate_cf_workers(%__MODULE__{opts: opts} = server) do
    cond do
      not ws_uri?(opts[:uri]) -> {:error, "Invalid cf-workers uri: #{inspect(opts[:uri])}"}
      not is_binary(opts[:password]) -> {:error, "Invalid cf-workers configuration"}
      true -> {:ok, %{server | client_type: :ws}}
    end
  end

  defp ws_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} when scheme in ["ws", "wss"] and is_binary(host) -> true
      _ -> false
    end
  end

  defp ws_uri?(%URI{scheme: scheme, host: host}) when scheme in ["ws", "wss"] and is_binary(host),
    do: true

  defp ws_uri?(_), do: false

  defp validate_socks5(%__MODULE__{opts: opts} = server) do
    port = opts[:port]

    if is_binary(opts[:host]) and is_integer(port) and port > 0 and port <= 65535 do
      {:ok, %{server | client_type: :socks5}}
    else
      {:error, "Invalid socks5 configuration"}
    end
  end

  # `opts` mixes the credential in with the endpoint, so a server cannot be
  # inspected wholesale — a profile in a crash report or a route in a log line
  # would carry the password. Print every field, with the secrets replaced.
  defimpl Inspect do
    import Inspect.Algebra

    alias PpClient.Redact

    def inspect(server, opts) do
      fields =
        server
        |> Map.from_struct()
        |> Map.put(:opts, Redact.setting(server.opts))
        |> Map.to_list()

      container_doc("#PpClient.ProxyServer<", fields, ">", opts, &field/2)
    end

    defp field({key, value}, opts), do: concat([to_string(key), ": ", to_doc(value, opts)])
  end
end
