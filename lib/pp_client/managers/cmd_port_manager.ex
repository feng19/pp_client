defmodule PpClient.CmdPortManager do
  @moduledoc """
  Runs the `cmd_ports:` of the config: external commands, such as `autossh`
  tunnels, that the client keeps alive alongside itself.

  Each entry is opened as a port. One that exits is restarted after a short
  delay, and on shutdown they are all sent `TERM` and given a few seconds to go
  before being killed — a tunnel left behind would keep its local port bound.

  Servers of type `socks5` are how a profile then reaches such a tunnel.
  """
  use GenServer, shutdown: 10_000
  require Logger

  @reconnect_delay 2_000
  @stop_timeout 5_000

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Replaces the running commands with `cmd_ports`, stopping the old ones first.
  """
  @spec reload([map()]) :: :ok
  def reload(cmd_ports) do
    GenServer.call(__MODULE__, {:reload, cmd_ports}, @stop_timeout * 2)
  end

  @doc """
  The commands and whether each is currently running.
  """
  @spec list() :: [map()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc """
  Stops one command and keeps it stopped: it is not restarted until `start/1`
  or `restart/1`.
  """
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(name), do: GenServer.call(__MODULE__, {:stop, name}, @stop_timeout * 2)

  @doc """
  Starts a command that is not running.
  """
  @spec start(String.t()) :: :ok | {:error, :not_found | :already_running | :executable_not_found}
  def start(name), do: GenServer.call(__MODULE__, {:start, name})

  @doc """
  Stops a command if it is running, then starts it again.
  """
  @spec restart(String.t()) :: :ok | {:error, :not_found | :executable_not_found}
  def restart(name), do: GenServer.call(__MODULE__, {:restart, name}, @stop_timeout * 2)

  ## Callbacks

  @impl true
  def init(_init_arg) do
    # Without trapping exits the supervisor's :shutdown would skip terminate/2.
    Process.flag(:trap_exit, true)
    {:ok, start_all(PpClient.Config.cmd_ports(), %{})}
  end

  @impl true
  def handle_call({:reload, cmd_ports}, _from, state) do
    stop_all(Map.values(state))
    state = start_all(cmd_ports, %{})
    notify()
    {:reply, :ok, state}
  end

  def handle_call({:stop, name}, _from, state) do
    case state do
      %{^name => cmd_port} ->
        stop_all([cmd_port])
        notify()
        {:reply, :ok, Map.put(state, name, halted(cmd_port))}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:start, name}, _from, state) do
    case state do
      %{^name => %{status: :running}} -> {:reply, {:error, :already_running}, state}
      %{^name => cmd_port} -> start_reply(cmd_port, state)
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:restart, name}, _from, state) do
    case state do
      %{^name => cmd_port} ->
        stop_all([cmd_port])
        start_reply(halted(cmd_port), state)

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, state |> Map.values() |> Enum.sort_by(& &1.name), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case find_by_port(state, port) do
      {name, _cmd_port} -> Logger.info("[#{name}] #{String.trim_trailing(data)}")
      nil -> :ok
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case find_by_port(state, port) do
      {name, cmd_port} ->
        Logger.warning("[#{name}] exited with status #{status}, restarting...")
        :erlang.start_timer(@reconnect_delay, self(), {:start, name})
        notify()
        {:noreply, Map.put(state, name, %{cmd_port | port: nil, os_pid: nil, status: :stopped})}

      nil ->
        {:noreply, state}
    end
  end

  # The link message that follows a port's exit; the exit_status is handled above.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  # A timer can outlive its entry (a reload in between), or fire for one that has
  # been started again since; only a stopped entry that still exists is started.
  def handle_info({:timeout, _ref, {:start, name}}, state) do
    case state do
      %{^name => %{status: :stopped} = cmd_port} ->
        state = start(cmd_port, state)
        notify()
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_info, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Logger.warning("cmd ports terminating by #{inspect(reason)}, stopping commands...")
    stop_all(Map.values(state))
  end

  ## Internals

  defp start_all(cmd_ports, state) do
    Enum.reduce(cmd_ports, state, fn %{name: name, cmd: cmd, args: args}, acc ->
      start(%{name: name, cmd: cmd, args: args, port: nil, os_pid: nil, status: :stopped}, acc)
    end)
  end

  defp start(%{name: name, cmd: cmd, args: args} = cmd_port, state) do
    case System.find_executable(cmd) do
      nil ->
        Logger.error("[#{name}] executable #{cmd} not found!")
        Map.put(state, name, cmd_port)

      exe ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        Logger.info("[#{name}] started, os_pid: #{os_pid}")
        Map.put(state, name, %{cmd_port | port: port, os_pid: os_pid, status: :running})
    end
  end

  defp halted(cmd_port), do: %{cmd_port | port: nil, os_pid: nil, status: :halted}

  defp start_reply(cmd_port, state) do
    state = start(cmd_port, state)
    notify()

    if Map.fetch!(state, cmd_port.name).status == :running do
      {:reply, :ok, state}
    else
      {:reply, {:error, :executable_not_found}, state}
    end
  end

  # PubSub only runs alongside the web UI.
  defp notify do
    if Process.whereis(PpClient.PubSub) do
      Phoenix.PubSub.broadcast(PpClient.PubSub, "cmd_ports", {:cmd_port_updated, nil})
    end
  end

  defp stop_all(cmd_ports) do
    running = Enum.filter(cmd_ports, &(&1.status == :running))
    Enum.each(running, &kill(&1.os_pid, "-TERM"))

    deadline = System.monotonic_time(:millisecond) + @stop_timeout

    Enum.each(running, fn %{name: name, port: port, os_pid: os_pid} ->
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^port, {:exit_status, _}} -> Logger.info("[#{name}] stopped.")
      after
        timeout ->
          Logger.warning("[#{name}] stop timeout, killing...")
          kill(os_pid, "-KILL")
      end
    end)
  end

  defp find_by_port(state, port) do
    Enum.find(state, fn {_name, cmd_port} -> cmd_port.port == port end)
  end

  defp kill(os_pid, signal) do
    System.cmd("kill", [signal, to_string(os_pid)], stderr_to_stdout: true)
  end
end
