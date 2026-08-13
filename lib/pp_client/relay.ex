defmodule PpClient.Relay do
  @moduledoc """
  Glue between a `ThousandIsland.Handler` and the raw upstream socket it proxies.

  The upstream socket is owned by the handler process itself, so both directions
  of the relay are plain socket operations: the handler writes with
  `:gen_tcp.send/2` and reads the `{:tcp, socket, data}` messages straight out of
  its own mailbox. There is no forwarder process in between, so a packet is no
  longer copied into another heap and rescheduled before reaching its peer.
  """

  @doc """
  Arms `socket` for `active: :once` delivery to `owner` and tells `owner` that
  the upstream is ready.

  The `:connected` cast is queued *before* the socket is armed so the owner
  always sees it ahead of any relayed data. Ownership is handed over only when
  the connection was established on someone else's behalf; the common case is
  the handler connecting for itself, where it is already the controlling process.
  """
  @spec attach(:gen_tcp.socket(), pid()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def attach(socket, owner) do
    GenServer.cast(owner, :connected)
    :ok = :inet.setopts(socket, active: :once)

    if owner == self() do
      {:ok, socket}
    else
      case :gen_tcp.controlling_process(socket, owner) do
        :ok -> {:ok, socket}
        {:error, reason} -> {:error, {:controlling_process, reason}}
      end
    end
  end

  @doc """
  Sends client data upstream, asking the handler to close when the upstream is
  already gone.
  """
  @spec forward(term(), iodata(), term()) :: {:continue, term()} | {:close, term()}
  def forward(client, data, state) do
    case PpClient.AutoSwitchClient.send(client, data) do
      :ok -> {:continue, state}
      {:error, _reason} -> {:close, state}
    end
  end

  @doc """
  Re-arms the handler's read timer.

  Thousand Island only refreshes it around `handle_data/3`, i.e. on *client*
  traffic. A tunnel that is busy streaming downstream — a long download, a
  server-sent event stream — would otherwise be torn down by the read timeout
  while being anything but idle.
  """
  @spec touch(ThousandIsland.Socket.t()) :: ThousandIsland.Socket.t()
  def touch(%ThousandIsland.Socket{read_timeout: :infinity} = socket), do: socket

  def touch(%ThousandIsland.Socket{read_timer: timer, read_timeout: timeout} = socket) do
    if timer do
      Process.cancel_timer(timer)

      # The timer may have fired before we got to cancel it; drop the message so
      # a live connection is not closed on a stale timeout.
      receive do
        :read_timeout -> :ok
      after
        0 -> :ok
      end
    end

    %{socket | read_timer: Process.send_after(self(), :read_timeout, timeout)}
  end

  @doc """
  Injects the upstream half of the relay into a `ThousandIsland.Handler`.

  Must come after `use ThousandIsland.Handler`: its generated `{:tcp, ...}`
  clauses are matched on the handler's own client socket, so they take the client
  side and the clauses below only ever see upstream traffic.
  """
  defmacro __using__(_opts) do
    quote do
      # A tunnel that writes downstream itself cannot re-arm our read timer, so
      # it asks us to. See `PpClient.WSClient.attach/2`.
      @impl GenServer
      def handle_cast(:touch, {socket, state}) do
        {:noreply, {PpClient.Relay.touch(socket), state}}
      end

      @impl GenServer
      def handle_info({:tcp, upstream, data}, {socket, state}) do
        # Re-arm before writing: at most one more upstream packet can queue up
        # while a slow client is being written to, which is the backpressure we
        # want on a tunnel.
        _ = :inet.setopts(upstream, active: :once)

        case ThousandIsland.Socket.send(socket, data) do
          :ok -> {:noreply, {PpClient.Relay.touch(socket), state}}
          {:error, _reason} -> {:stop, :normal, {socket, state}}
        end
      end

      def handle_info({:tcp_closed, _upstream}, {socket, state}) do
        {:stop, :normal, {socket, state}}
      end

      def handle_info({:tcp_error, _upstream, _reason}, {socket, state}) do
        {:stop, :normal, {socket, state}}
      end

      # The WebSocket route still runs in a linked process; its death ends the
      # tunnel.
      def handle_info({:EXIT, _pid, _reason}, {socket, state}) do
        {:stop, :normal, {socket, state}}
      end
    end
  end
end
