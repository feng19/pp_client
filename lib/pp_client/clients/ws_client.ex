defmodule PpClient.WSClient do
  @moduledoc false
  use Wind.Client
  alias Plug.Crypto.MessageEncryptor
  alias PpClient.{BrowserHeaders, TLSProfile}

  @sign_secret "90de3456asxdfrtg"
  @domain 0x03

  def start_link(target, %{servers: servers}, parent) do
    server = Enum.random(servers)
    start_link(target, [{:type, server.type} | server.opts], parent)
  end

  def start_link(target, setting, parent) when is_list(setting) do
    start_link(target, Map.new(setting), parent)
  end

  def start_link(target, setting, parent) when is_map(setting) do
    first_frame = get_first_frame_by_type(setting, target)

    uri =
      case setting.uri do
        uri when is_binary(uri) -> URI.parse(uri)
        uri = %URI{} -> uri
      end

    headers =
      uri
      |> BrowserHeaders.headers(setting)
      |> BrowserHeaders.merge(get_headers_by_type(setting, target))

    Wind.Client.start_link(__MODULE__,
      uri: uri,
      headers: headers,
      http_opts: [
        protocols: [:http1],
        # Mint lowercases every header name unless told otherwise; browsers do
        # not, so this keeps the casing we set in BrowserHeaders.
        case_sensitive_headers: true,
        transport_opts: TLSProfile.transport_opts(uri, setting)
      ],
      pp: %{setting: setting, first_frame: first_frame, parent: parent}
    )
  end

  def send(pid, data) do
    Wind.Client.send(pid, {:binary, data})
  end

  @doc """
  Hands the client socket over so downstream frames are written to it directly
  instead of being relayed through the owner process.

  The owner calls this once it has written its own protocol greeting (the HTTP
  `200`, the SOCKS5 success reply). That keeps a single writer on the socket at
  any moment — the owner up to this point, the tunnel from here on — and frames
  that arrive before the handover are flushed in order when it lands.
  """
  def attach(pid, socket) do
    GenServer.cast(pid, {:attach, socket})
  end

  @impl true
  def handle_connect(state) do
    %{first_frame: first_frame, parent: parent} = Keyword.fetch!(state.opts, :pp)
    GenServer.cast(parent, :connected)

    if first_frame do
      {:reply, first_frame, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_frame({:binary, data}, state) do
    {:noreply, relay(data, state)}
  end

  def handle_frame({:close, _, _}, state) do
    close(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:attach, socket}, state) do
    %{pending: pending} = tunnel = tunnel(state)

    tunnel = %{
      tunnel
      | socket: socket,
        pending: [],
        # The owner just wrote its greeting, so its read timer is fresh.
        touched_at: System.monotonic_time(:millisecond)
    }

    state = put_tunnel(state, tunnel)

    pending
    |> Enum.reverse()
    |> Enum.reduce(state, &relay(&1, &2))
    |> then(&{:noreply, &1})
  end

  # Wind marks handle_cast/2 overridable; everything else is its own.
  def handle_cast(message, state), do: super(message, state)

  @tunnel %{socket: nil, pending: [], touched_at: nil}

  defp tunnel(state), do: Map.get(state, :tunnel, @tunnel)
  defp put_tunnel(state, tunnel), do: Map.put(state, :tunnel, tunnel)

  defp relay(data, state) do
    case tunnel(state) do
      %{socket: nil} = tunnel ->
        put_tunnel(state, %{tunnel | pending: [data | tunnel.pending]})

      %{socket: socket} = tunnel ->
        case ThousandIsland.Socket.send(socket, data) do
          :ok ->
            put_tunnel(state, touch(socket, tunnel, state))

          {:error, _reason} ->
            close(state)
            state
        end
    end
  end

  # The owner's read timer is only refreshed by traffic it handles itself, and it
  # no longer sees downstream frames. Nudge it at half the timeout so a tunnel
  # that is only downloading is not reaped, without a message per frame.
  defp touch(%ThousandIsland.Socket{read_timeout: :infinity}, tunnel, _state), do: tunnel

  defp touch(%ThousandIsland.Socket{read_timeout: timeout}, tunnel, state) do
    now = System.monotonic_time(:millisecond)

    if now - tunnel.touched_at >= div(timeout, 2) do
      %{parent: parent} = Keyword.fetch!(state.opts, :pp)
      GenServer.cast(parent, :touch)
      %{tunnel | touched_at: now}
    else
      tunnel
    end
  end

  defp close(state) do
    %{parent: parent} = Keyword.fetch!(state.opts, :pp)
    GenServer.cast(parent, :close)
  end

  defp get_first_frame_by_type(
         %{type: "exps", encrypt_type: encrypt_type, encrypt_key: key},
         {_type, hostname, port}
       ) do
    len = byte_size(hostname)
    target_binary = <<@domain, port::16, len, hostname::binary-size(len)>>

    data =
      case encrypt_type do
        :none -> target_binary
        :once -> MessageEncryptor.encrypt(target_binary, key, @sign_secret)
      end

    {:binary, data}
  end

  defp get_first_frame_by_type(_, _), do: nil

  defp get_headers_by_type(%{type: "cf-workers", password: password}, {_type, hostname, port}) do
    target = Enum.join([hostname, port], ":")
    [{"Authorization", password}, {"X-Proxy-Target", target}]
  end

  defp get_headers_by_type(_, _), do: []
end
