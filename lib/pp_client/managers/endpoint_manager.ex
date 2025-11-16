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

  @doc """
  启动 EndpointManager GenServer。

  由 Application 监督树自动调用。
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  初始化 GenServer 状态。

  当前实现不需要维护状态，因为所有数据都存储在 ETS 表中。
  """
  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @doc """
  处理同步调用。

  支持的操作：
  - `{:start, endpoint}` - 启动端点
  - `{:stop, endpoint}` - 停止端点
  - `{:restart, endpoint}` - 重启端点
  """
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

  @doc """
  启用端点。

  启动端点服务并更新 ETS 表中的状态。

  ## 参数
  - `endpoint` - 要启用的端点结构体

  ## 返回值
  - `:ok` - 成功启用
  - `{:error, reason}` - 启用失败
  """
  @spec enable(Endpoint.t()) :: :ok | {:error, term()}
  def enable(%Endpoint{} = endpoint) do
    case start(endpoint) do
      {:ok, _pid} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  禁用端点。

  停止端点服务并更新 ETS 表中的状态。

  ## 参数
  - `endpoint` - 要禁用的端点结构体

  ## 返回值
  - `{:ok, :disabled}` - 成功禁用
  - `{:error, reason}` - 禁用失败
  """
  @spec disable(Endpoint.t()) :: {:ok, :disabled} | {:error, term()}
  def disable(%Endpoint{} = endpoint) do
    case stop(endpoint) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  启动端点服务。

  通过 GenServer 调用启动指定端点。

  ## 参数
  - `endpoint` - 要启动的端点结构体

  ## 返回值
  - `{:ok, pid}` - 成功启动，返回进程 PID
  - `{:error, reason}` - 启动失败
  """
  @spec start(Endpoint.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Endpoint{} = endpoint) do
    GenServer.call(__MODULE__, {:start, endpoint}, :timer.seconds(10))
  end

  @doc """
  停止端点服务。

  通过 GenServer 调用停止指定端点。

  ## 参数
  - `endpoint` - 要停止的端点结构体

  ## 返回值
  - `:ok` - 成功停止
  - `{:error, reason}` - 停止失败
  """
  @spec stop(Endpoint.t()) :: :ok | {:error, term()}
  def stop(%Endpoint{} = endpoint) do
    GenServer.call(__MODULE__, {:stop, endpoint}, :timer.seconds(10))
  end

  @doc """
  重启端点服务。

  通过 GenServer 调用重启指定端点。

  ## 参数
  - `endpoint` - 要重启的端点结构体

  ## 返回值
  - `{:ok, pid}` - 成功重启，返回进程 PID
  - `{:error, reason}` - 重启失败
  """
  @spec restart(Endpoint.t()) :: {:ok, pid()} | {:error, term()}
  def restart(%Endpoint{} = endpoint) do
    GenServer.call(__MODULE__, {:restart, endpoint}, :timer.seconds(10))
  end

  @doc """
  获取所有端点列表。

  从 ETS 表中读取所有端点配置。

  ## 返回值
  端点列表，按端口号排序
  """
  @spec all_endpoints() :: [Endpoint.t()]
  def all_endpoints do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_port, endpoint} -> endpoint end)
    |> Enum.sort_by(& &1.port)
  end

  @doc """
  根据端口号获取端点配置。

  ## 参数
  - `port` - 端口号

  ## 返回值
  - `{:ok, endpoint}` - 找到端点
  - `{:error, :not_found}` - 端点不存在
  - `{:error, :invalid_port}` - 无效的端口号

  ## 示例

      iex> EndpointManager.get_endpoint(1080)
      {:ok, %Endpoint{port: 1080, ...}}

      iex> EndpointManager.get_endpoint(9999)
      {:error, :not_found}
  """
  @spec get_endpoint(non_neg_integer()) ::
          {:ok, Endpoint.t()} | {:error, :not_found | :invalid_port}
  def get_endpoint(port) when is_integer(port) and port > 0 and port <= 65535 do
    case :ets.lookup(@table, port) do
      [{^port, endpoint}] -> {:ok, endpoint}
      [] -> {:error, :not_found}
    end
  end

  def get_endpoint(_port), do: {:error, :invalid_port}

  @doc """
  获取所有已启用的端点列表。

  使用 ETS match 直接过滤，比先获取所有再过滤更高效。

  ## 返回值
  已启用的端点列表，按端口号排序
  """
  @spec enabled_endpoints() :: [Endpoint.t()]
  def enabled_endpoints do
    # 使用 ETS match_object 直接过滤，避免加载所有数据
    match_spec = [
      {{:_, %Endpoint{enable: true, port: :"$1", type: :"$2", ip: :"$3", options: :"$4"}}, [],
       [:"$_"]}
    ]

    @table
    |> :ets.select(match_spec)
    |> Enum.map(fn {_port, endpoint} -> endpoint end)
    |> Enum.sort_by(& &1.port)
  end

  @doc """
  检查指定端口的端点是否存在。

  使用 ETS member 检查，比 lookup 更高效。

  ## 参数
  - `port` - 端口号

  ## 返回值
  - `true` - 端点存在
  - `false` - 端点不存在
  """
  @spec exists?(non_neg_integer()) :: boolean()
  def exists?(port) when is_integer(port) and port > 0 and port <= 65535 do
    :ets.member(@table, port)
  end

  def exists?(_port), do: false

  @doc """
  检查端点是否正在运行。

  通过查询 EndpointSupervisor 的子进程列表来判断。

  ## 参数
  - `endpoint` - 端点结构体

  ## 返回值
  - `true` - 端点正在运行
  - `false` - 端点未运行
  """
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
