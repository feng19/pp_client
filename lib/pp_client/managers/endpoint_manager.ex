defmodule PpClient.EndpointManager do
  @moduledoc """
  Endpoint Manager

  manage ets table
    {endpoint.port, endpoint(Endpoint.t())}
  """
  use Supervisor
  require Logger
  alias PpClient.Endpoint

  @table :endpoints

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = load_endpoints_from_config()
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns all endpoints stored in the ETS table.

  ## Examples

      iex> PpClient.EndpointManager.all_endpoints()
      [%PpClient.Endpoint{port: 1080, ...}, ...]

  """
  @spec all_endpoints() :: [Endpoint.t()]
  def all_endpoints do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_port, endpoint} -> endpoint end)
  end

  @doc """
  Returns an endpoint by port number.

  ## Examples

      iex> PpClient.EndpointManager.get_endpoint(1080)
      {:ok, %PpClient.Endpoint{port: 1080, ...}}

      iex> PpClient.EndpointManager.get_endpoint(9999)
      {:error, :not_found}

  """
  @spec get_endpoint(non_neg_integer()) :: {:ok, Endpoint.t()} | {:error, :not_found}
  def get_endpoint(port) when is_integer(port) do
    case :ets.lookup(@table, port) do
      [{^port, endpoint}] -> {:ok, endpoint}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns all enabled endpoints.

  ## Examples

      iex> PpClient.EndpointManager.enabled_endpoints()
      [%PpClient.Endpoint{port: 1080, enable: true}, ...]

  """
  @spec enabled_endpoints() :: [Endpoint.t()]
  def enabled_endpoints do
    all_endpoints()
    |> Enum.filter(& &1.enable)
  end

  @doc """
  Checks if an endpoint exists for the given port.

  ## Examples

      iex> PpClient.EndpointManager.exists?(1080)
      true

  """
  @spec exists?(non_neg_integer()) :: boolean()
  def exists?(port) when is_integer(port) do
    case :ets.lookup(@table, port) do
      [{^port, _endpoint}] -> true
      [] -> false
    end
  end

  if Mix.env() == :test do
    defp load_endpoints_from_config, do: []
  else
    defp load_endpoints_from_config do
      if File.exists?("pp_config.exs") do
        {endpoints, _} = Code.eval_file("pp_config.exs")
        endpoints
      else
        Logger.warning("NOT found the pp_config.exs")
        []
      end
      |> child_specs()
    end
  end

  defp child_specs(endpoints) do
    endpoints
    |> Stream.map(&Endpoint.new/1)
    |> Stream.uniq_by(& &1.port)
    |> Stream.map(fn endpoint ->
      # Insert port information into ETS table
      :ets.insert(@table, {endpoint.port, endpoint})
      endpoint
    end)
    |> Enum.reduce([], fn
      %{enable: false}, acc -> acc
      endpoint, acc -> [{Endpoint, endpoint} | acc]
    end)
  end

  def enable(endpoint), do: start(endpoint)

  def start(endpoint) do
    port = endpoint.port
    :ets.insert(@table, {port, endpoint})

    case Supervisor.start_child(__MODULE__, {Endpoint, endpoint}) do
      {:ok, pid} ->
        Logger.info("Started endpoint on port #{port}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start endpoint on port #{port}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def disable(endpoint), do: stop(endpoint)

  def stop(endpoint) do
    port = endpoint.port
    child_id = Endpoint.child_id(endpoint)

    case Supervisor.terminate_child(__MODULE__, child_id) do
      :ok ->
        Logger.info("Stopped existing endpoint on port #{port}")
        Supervisor.delete_child(__MODULE__, child_id)

      {:error, :not_found} ->
        Logger.info("No existing endpoint found on port #{port}")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Failed to terminate child for port #{port}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def restart(endpoint) do
    port = endpoint.port
    child_id = Endpoint.child_id(endpoint)

    # First stop existing child process (if it exists)
    with :ok <- terminate_existing_child(child_id, port),
         :ok <- update_ets_table(port, endpoint),
         {:ok, pid} <- start_new_child(endpoint, port) do
      {:ok, pid}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminate_existing_child(child_id, port) do
    case Supervisor.terminate_child(__MODULE__, child_id) do
      :ok ->
        Logger.info("Stopped existing endpoint on port #{port}")
        Supervisor.delete_child(__MODULE__, child_id)
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to terminate child for port #{port}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp update_ets_table(port, endpoint) do
    :ets.insert(@table, {port, endpoint})
    :ok
  end

  defp start_new_child(endpoint, port) do
    case Supervisor.start_child(__MODULE__, {Endpoint, endpoint}) do
      {:ok, pid} ->
        Logger.info("Restarted endpoint on port #{port}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to restart endpoint on port #{port}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
