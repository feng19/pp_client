defmodule PpClient.DirectClient do
  @moduledoc """
  Direct Client
  """
  use GenServer
  require Logger

  def start_link(target, parent) do
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

  defp connect(host, port, 0) do
    save_connect_failed_host(host, port)
    {:error, :connect_failure}
  end

  defp connect(host, port, retry_times) do
    case :gen_tcp.connect(host, port, [:binary, {:active, false}], 5000) do
      {:error, _error} -> connect(host, port, retry_times - 1)
      result -> result
    end
  end

  defp save_connect_failed_host(host, port) do
    failure_key = {host, port}
    current_time = System.system_time(:second)

    # Insert or update failure count atomically
    case :ets.lookup(:connect_failed, failure_key) do
      [{^failure_key, existing_record}] ->
        # Update existing record with incremented count
        updated_record = %{
          existing_record
          | timestamp: current_time,
            count: existing_record.count + 1
        }

        :ets.insert(:connect_failed, {failure_key, updated_record})

      [] ->
        # Insert new failure record
        failure_record = %{
          timestamp: current_time,
          host: host,
          port: port,
          count: 1
        }

        :ets.insert(:connect_failed, {failure_key, failure_record})
    end
  end
end
