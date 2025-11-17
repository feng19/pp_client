defmodule PpClient.EndpointManager do
  @moduledoc """
  Endpoint Manager

  manage ets table
    {endpoint.port, endpoint(Endpoint.t())}
  """
  use GenServer
  require Logger
  alias PpClient.Endpoint

  @table :endpoints
  @supervisor PpClient.EndpointSupervisor

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start, endpoint}, _from, state) do
    result = do_start(endpoint)
    {:reply, result, state}
  end

  def handle_call({:stop, endpoint}, _from, state) do
    result = do_stop(endpoint)
    {:reply, result, state}
  end

  def handle_call({:restart, endpoint}, _from, state) do
    result = do_restart(endpoint)
    {:reply, result, state}
  end

  @spec enable(Endpoint.t()) :: :ok | {:error, term()}
  def enable(%Endpoint{} = endpoint) do
    case start(endpoint) do
      {:ok, _pid} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec disable(Endpoint.t()) :: {:ok, :disabled} | {:error, term()}
  def disable(%Endpoint{} = endpoint) do
    case stop(endpoint) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec start(Endpoint.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Endpoint{} = endpoint) do
    GenServer.call(__MODULE__, {:start, endpoint}, :timer.seconds(10))
  end

  @spec stop(Endpoint.t()) :: :ok | {:error, term()}
  def stop(%Endpoint{} = endpoint) do
    GenServer.call(__MODULE__, {:stop, endpoint}, :timer.seconds(10))
  end

  @spec restart(Endpoint.t()) :: {:ok, pid()} | {:error, term()}
  def restart(%Endpoint{} = endpoint) do
    GenServer.call(__MODULE__, {:restart, endpoint}, :timer.seconds(10))
  end

  @spec all_endpoints() :: [Endpoint.t()]
  def all_endpoints do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_port, endpoint} -> endpoint end)
    |> Enum.sort_by(& &1.port)
  end

  @spec get_endpoint(non_neg_integer()) ::
          {:ok, Endpoint.t()} | {:error, :not_found | :invalid_port}
  def get_endpoint(port) when is_integer(port) and port > 0 and port <= 65535 do
    case :ets.lookup(@table, port) do
      [{^port, endpoint}] -> {:ok, endpoint}
      [] -> {:error, :not_found}
    end
  end

  def get_endpoint(_port), do: {:error, :invalid_port}

  @spec enabled_endpoints() :: [Endpoint.t()]
  def enabled_endpoints do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_port, endpoint} -> endpoint end)
    |> Enum.sort_by(& &1.port)
  end

  @spec exists?(non_neg_integer()) :: boolean()
  def exists?(port) when is_integer(port) and port > 0 and port <= 65535 do
    :ets.member(@table, port)
  end

  def exists?(_port), do: false

  @spec running?(Endpoint.t()) :: boolean()
  def running?(%Endpoint{} = endpoint) do
    child_id = Endpoint.child_id(endpoint)

    case Supervisor.which_children(@supervisor) do
      children when is_list(children) ->
        Enum.any?(children, fn
          {^child_id, pid, _, _} when is_pid(pid) -> true
          _ -> false
        end)

      _ ->
        false
    end
  end

  # Private functions

  defp do_start(%Endpoint{port: port} = endpoint) do
    child_id = Endpoint.child_id(endpoint)

    case Supervisor.start_child(@supervisor, {Endpoint, endpoint}) do
      {:ok, pid} ->
        update_endpoint(%{endpoint | enable: true})
        Logger.info("Started endpoint on port #{port}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.info("Endpoint on port #{port} is already running")
        update_endpoint(%{endpoint | enable: true})
        {:ok, pid}

      {:error, :already_present} ->
        # 子进程规范已存在但未运行，先删除再重新启动
        Logger.info("Restarting existing endpoint on port #{port}")
        Supervisor.delete_child(@supervisor, child_id)
        do_start(endpoint)

      {:error, reason} ->
        update_endpoint(%{endpoint | enable: false})
        Logger.error("Failed to start endpoint on port #{port}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_stop(%Endpoint{port: port} = endpoint) do
    child_id = Endpoint.child_id(endpoint)

    # 先更新状态为禁用
    update_endpoint(%{endpoint | enable: false})

    case Supervisor.terminate_child(@supervisor, child_id) do
      :ok ->
        Logger.info("Stopped endpoint on port #{port}")
        # 删除子进程规范以释放资源
        case Supervisor.delete_child(@supervisor, child_id) do
          :ok ->
            :ok

          {:error, :not_found} ->
            # 子进程已被删除，这是正常情况
            :ok

          {:error, reason} ->
            Logger.warning("Failed to delete child spec for port #{port}: #{inspect(reason)}")
            :ok
        end

      {:error, :not_found} ->
        Logger.info("Endpoint on port #{port} is not running")
        :ok

      {:error, reason} ->
        Logger.error("Failed to terminate endpoint on port #{port}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_restart(%Endpoint{port: port} = endpoint) do
    child_id = Endpoint.child_id(endpoint)

    with :ok <- Supervisor.terminate_child(@supervisor, child_id) do
      Logger.info("Stopped endpoint on port #{port}")
      update_endpoint(%{endpoint | enable: false})

      case Supervisor.restart_child(@supervisor, child_id) do
        {:ok, child} ->
          update_endpoint(%{endpoint | enable: true})
          Logger.info("Restarted endpoint on port #{port}")
          {:ok, child}

        {:ok, child, _info} ->
          update_endpoint(%{endpoint | enable: true})
          Logger.info("Restarted endpoint on port #{port}")
          {:ok, child}

        {:error, :not_found} ->
          # 子进程不存在，尝试启动
          Logger.info("Endpoint on port #{port} not found, starting instead")
          do_start(endpoint)

        {:error, reason} ->
          update_endpoint(%{endpoint | enable: false})
          Logger.error("Failed to restart endpoint on port #{port}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp update_endpoint(%Endpoint{port: port} = endpoint) do
    :ets.insert(@table, {port, endpoint})
  end
end
