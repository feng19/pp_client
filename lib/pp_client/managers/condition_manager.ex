defmodule PpClient.ConditionManager do
  @moduledoc """
  Condition Manager

  Manages conditions in an ETS table with the following structure:
    {condition_id, condition(%Condition{})}

  Provides APIs for CRUD operations and enable/disable functionality.
  """
  use GenServer
  require Logger
  alias PpClient.Condition

  @table :conditions

  ## Client API

  @doc """
  Starts the ConditionManager GenServer.

  ## Examples

      iex> PpClient.ConditionManager.start_link([])
      {:ok, pid}

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Returns all conditions stored in the ETS table.

  ## Examples

      iex> PpClient.ConditionManager.all_conditions()
      [%PpClient.Condition{id: 1, ...}, ...]

  """
  @spec all_conditions() :: [Condition.t()]
  def all_conditions do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, condition} -> condition end)
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  Returns a condition by its ID.

  ## Examples

      iex> PpClient.ConditionManager.get_condition(1)
      {:ok, %PpClient.Condition{id: 1, ...}}

      iex> PpClient.ConditionManager.get_condition(999)
      {:error, :not_found}

  """
  @spec get_condition(non_neg_integer()) :: {:ok, Condition.t()} | {:error, :not_found}
  def get_condition(id) when is_integer(id) do
    case :ets.lookup(@table, id) do
      [{^id, condition}] -> {:ok, condition}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns all enabled conditions.

  ## Examples

      iex> PpClient.ConditionManager.enabled_conditions()
      [%PpClient.Condition{id: 1, enabled: true}, ...]

  """
  @spec enabled_conditions() :: [Condition.t()]
  def enabled_conditions do
    all_conditions()
    |> Enum.filter(& &1.enabled)
  end

  @doc """
  Adds a new condition to the ETS table.

  ## Examples

      iex> condition = %PpClient.Condition{condition: ~r/example/, profile_name: "proxy1", enabled: true}
      iex> PpClient.ConditionManager.add_condition(condition)
      {:ok, %PpClient.Condition{id: 1, ...}}

  """
  @spec add_condition(Condition.t()) :: {:ok, Condition.t()} | {:error, term()}
  def add_condition(%Condition{} = condition) do
    GenServer.call(__MODULE__, {:add_condition, condition})
  end

  @doc """
  Updates an existing condition in the ETS table.

  ## Examples

      iex> condition = %PpClient.Condition{id: 1, condition: ~r/updated/, profile_name: "proxy2", enabled: true}
      iex> PpClient.ConditionManager.update_condition(condition)
      {:ok, %PpClient.Condition{id: 1, ...}}

      iex> PpClient.ConditionManager.update_condition(%PpClient.Condition{id: 999, ...})
      {:error, :not_found}

  """
  @spec update_condition(Condition.t()) :: {:ok, Condition.t()} | {:error, :not_found}
  def update_condition(%Condition{id: id} = condition) when not is_nil(id) do
    GenServer.call(__MODULE__, {:update_condition, condition})
  end

  @doc """
  Deletes a condition from the ETS table by its ID.

  ## Examples

      iex> PpClient.ConditionManager.delete_condition(1)
      :ok

      iex> PpClient.ConditionManager.delete_condition(999)
      {:error, :not_found}

  """
  @spec delete_condition(non_neg_integer()) :: :ok | {:error, :not_found}
  def delete_condition(id) when is_integer(id) do
    GenServer.call(__MODULE__, {:delete_condition, id})
  end

  @doc """
  Enables a condition by its ID.

  ## Examples

      iex> PpClient.ConditionManager.enable_condition(1)
      {:ok, %PpClient.Condition{id: 1, enabled: true}}

  """
  @spec enable_condition(non_neg_integer()) :: {:ok, Condition.t()} | {:error, :not_found}
  def enable_condition(id) when is_integer(id) do
    GenServer.call(__MODULE__, {:enable_condition, id})
  end

  @doc """
  Disables a condition by its ID.

  ## Examples

      iex> PpClient.ConditionManager.disable_condition(1)
      {:ok, %PpClient.Condition{id: 1, enabled: false}}

  """
  @spec disable_condition(non_neg_integer()) :: {:ok, Condition.t()} | {:error, :not_found}
  def disable_condition(id) when is_integer(id) do
    GenServer.call(__MODULE__, {:disable_condition, id})
  end

  @doc """
  Checks if a condition exists for the given ID.

  ## Examples

      iex> PpClient.ConditionManager.exists?(1)
      true

      iex> PpClient.ConditionManager.exists?(999)
      false

  """
  @spec exists?(non_neg_integer()) :: boolean()
  def exists?(id) when is_integer(id) do
    case :ets.lookup(@table, id) do
      [{^id, _condition}] -> true
      [] -> false
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(_init_arg) do
    load_conditions_from_config()
    {:ok, %{next_id: 1}}
  end

  @impl true
  def handle_call({:add_condition, condition}, _from, %{next_id: next_id} = state) do
    condition_with_id = Map.put(condition, :id, next_id)

    case :ets.insert_new(@table, {next_id, condition_with_id}) do
      true ->
        Logger.info("Added condition with ID #{next_id}")
        {:reply, {:ok, condition_with_id}, %{state | next_id: next_id + 1}}

      false ->
        Logger.error("Failed to add condition with ID #{next_id}")
        {:reply, {:error, :already_exists}, state}
    end
  end

  @impl true
  def handle_call({:update_condition, %{id: id} = condition}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, _old_condition}] ->
        :ets.insert(@table, {id, condition})
        Logger.info("Updated condition with ID #{id}")
        {:reply, {:ok, condition}, state}

      [] ->
        Logger.warning("Condition with ID #{id} not found for update")
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_condition, id}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, _condition}] ->
        :ets.delete(@table, id)
        Logger.info("Deleted condition with ID #{id}")
        {:reply, :ok, state}

      [] ->
        Logger.warning("Condition with ID #{id} not found for deletion")
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:enable_condition, id}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, condition}] ->
        updated_condition = %{condition | enabled: true}
        :ets.insert(@table, {id, updated_condition})
        Logger.info("Enabled condition with ID #{id}")
        {:reply, {:ok, updated_condition}, state}

      [] ->
        Logger.warning("Condition with ID #{id} not found for enabling")
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:disable_condition, id}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, condition}] ->
        updated_condition = %{condition | enabled: false}
        :ets.insert(@table, {id, updated_condition})
        Logger.info("Disabled condition with ID #{id}")
        {:reply, {:ok, updated_condition}, state}

      [] ->
        Logger.warning("Condition with ID #{id} not found for disabling")
        {:reply, {:error, :not_found}, state}
    end
  end

  ## Private Functions

  defp load_conditions_from_config do
    # Load conditions from config file if it exists
    # This can be extended to load from a conditions config file
    # similar to how EndpointManager loads from pp_config.exs
    :ok
  end
end
