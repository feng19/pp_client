defmodule PpClient.DirectClient do
  @moduledoc """
  Direct Client
  """
  use GenServer
  require Logger

  def start_link(_opts, target, parent) do
    GenServer.start_link(__MODULE__, target: target, parent: parent)
  end

  def send(pid, data) do
    GenServer.cast(pid, {:binary, data})
  end

  @impl true
  def init(target: target, parent: parent) do
    {:ok, %{remote: nil, parent: parent}, {:continue, {:connect_server, target}}}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, %{remote: remote, parent: parent} = state) do
    :ok = :inet.setopts(remote, active: :once)
    GenServer.cast(parent, {:send, data})
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _}, state), do: {:stop, :normal, state}

  def handle_info({:tcp_error, _, reason}, state) do
    Logger.error(inspect(reason))
    {:stop, :normal, state}
  end

  def handle_info(_Info, state), do: {:ok, state}

  @impl true
  def handle_continue({:connect_server, target}, %{parent: parent} = state) do
    case connect(target) do
      {:ok, remote} ->
        :ok = :inet.setopts(remote, active: :once)
        GenServer.cast(parent, :connected)
        {:noreply, %{state | remote: remote}}

      {:error, reason} ->
        Logger.error("Direct connection failed: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_cast({:binary, data}, %{socket: socket} = state) do
    :gen_tcp.send(socket, data)
    {:noreply, state}
  end

  defp connect(%{host: host, port: port}), do: connect(host, port, 2)
  defp connect(_, _, 0), do: {:error, :connect_failure}

  defp connect(address, port, retry_times) do
    case :gen_tcp.connect(address, port, [:binary, {:active, false}], 5000) do
      {:error, _error} -> connect(address, port, retry_times - 1)
      return -> return
    end
  end
end
