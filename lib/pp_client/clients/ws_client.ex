defmodule PpClient.WSClient do
  @moduledoc false
  use Wind.Client
  require Logger
  alias Plug.Crypto.MessageEncryptor
  alias PpClient.{BrowserHeaders, DnsRecordManager, Redact, TLSProfile}

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

    http_opts = [
      protocols: [:http1],
      # Mint lowercases every header name unless told otherwise; browsers do
      # not, so this keeps the casing we set in BrowserHeaders.
      case_sensitive_headers: true,
      transport_opts: TLSProfile.transport_opts(uri, setting)
    ]

    # A DNS record for this host moves the dial to its IP and leaves the domain
    # to Mint's `:hostname`, which is what SNI and the `Host` header are built
    # from. The headers above are already built from the original URI — `Origin`
    # among them — so they carry the domain either way.
    {dial_uri, http_opts} = DnsRecordManager.dial(uri, http_opts)

    Wind.Client.start_link(__MODULE__,
      uri: dial_uri,
      headers: headers,
      http_opts: http_opts,
      # The setting is kept for diagnostics only — everything the tunnel needs
      # from it is already baked into `headers` and `first_frame` above — so the
      # copy in state is the redacted one.
      pp: %{
        setting: Redact.setting(setting),
        first_frame: first_frame,
        parent: parent,
        host: uri.host
      }
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

    # The upgrade request is on the wire and Wind reads the headers only to send
    # it, so the credential one of them carries has no reason to sit in state for
    # the life of the tunnel.
    state = %{state | opts: Keyword.replace_lazy(state.opts, :headers, &Redact.headers/1)}

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

  # The upstream going away is how a tunnel normally ends — the target hung up,
  # the worker was recycled, the client vanished. Wind's default `handle_error/2`
  # stops with `{:error, reason}`, which logs a crash report carrying the whole
  # Mint connection and TLS profile. Tell the owner and stop quietly instead.
  @impl true
  def handle_error(%Mint.TransportError{reason: reason}, state)
      when reason in [:closed, :econnreset, :epipe, :etimedout] do
    close(state)
    {:stop, :normal, state}
  end

  def handle_error(reason, state) do
    uri = Keyword.fetch!(state.opts, :uri)
    Logger.warning("ws client #{uri}#{dns_note(state)} error: #{inspect(reason)}")
    close(state)
    {:stop, :normal, state}
  end

  # The URI above holds an IP whenever a DNS record was applied, so name the
  # domain it came from — a record pointing at the wrong address is otherwise
  # indistinguishable from an upstream that is simply down.
  defp dns_note(state) do
    uri = Keyword.fetch!(state.opts, :uri)
    host = Keyword.fetch!(state.opts, :pp)[:host]

    if is_binary(host) and host != uri.host do
      " (DNS record #{host} -> #{uri.host})"
    else
      ""
    end
  end

  # Until the upgrade lands there is no websocket, so Wind's decode clause does
  # not match and its catch-all would stop with `{:error, message}`. A transport
  # that drops mid-handshake ends the tunnel the same way as one that drops
  # mid-frame; anything still buffered arrived as its own message before this.
  @impl true
  def handle_info({closed, _socket}, state) when closed in [:ssl_closed, :tcp_closed] do
    close(state)
    {:stop, :normal, state}
  end

  def handle_info({error, _socket, reason}, state) when error in [:ssl_error, :tcp_error] do
    handle_error(reason, state)
  end

  # Wind marks handle_info/2 overridable; everything else is its own.
  def handle_info(message, state), do: super(message, state)

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
