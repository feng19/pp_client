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

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec all_conditions() :: [Condition.t()]
  def all_conditions do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, condition} -> condition end)
    |> Enum.sort_by(& &1.id)
  end

  @spec get_condition(non_neg_integer()) :: {:ok, Condition.t()} | {:error, :not_found}
  def get_condition(id) when is_integer(id) do
    case :ets.lookup(@table, id) do
      [{^id, condition}] -> {:ok, condition}
      [] -> {:error, :not_found}
    end
  end

  @spec enabled_conditions() :: [Condition.t()]
  def enabled_conditions do
    all_conditions()
    |> Enum.filter(& &1.enabled)
  end

  @spec add_condition(Condition.t()) :: {:ok, Condition.t()} | {:error, term()}
  def add_condition(%Condition{} = condition) do
    GenServer.call(__MODULE__, {:add_condition, condition})
  end

  @spec update_condition(Condition.t()) :: {:ok, Condition.t()} | {:error, :not_found}
  def update_condition(%Condition{id: id} = condition) when not is_nil(id) do
    GenServer.call(__MODULE__, {:update_condition, condition})
  end

  @spec delete_condition(non_neg_integer()) :: :ok | {:error, :not_found}
  def delete_condition(id) when is_integer(id) do
    GenServer.call(__MODULE__, {:delete_condition, id})
  end

  @spec enable_condition(non_neg_integer()) :: {:ok, Condition.t()} | {:error, :not_found}
  def enable_condition(id) when is_integer(id) do
    GenServer.call(__MODULE__, {:enable_condition, id})
  end

  @spec disable_condition(non_neg_integer()) :: {:ok, Condition.t()} | {:error, :not_found}
  def disable_condition(id) when is_integer(id) do
    GenServer.call(__MODULE__, {:disable_condition, id})
  end

  @spec exists?(non_neg_integer()) :: boolean()
  def exists?(id) when is_integer(id) do
    case :ets.lookup(@table, id) do
      [{^id, _condition}] -> true
      [] -> false
    end
  end

  @spec get_connect_failed_hosts() :: [map()]
  def get_connect_failed_hosts do
    case :ets.whereis(:connect_failed) do
      :undefined ->
        []

      _table ->
        :connect_failed
        |> :ets.tab2list()
        |> Enum.map(fn {{_host, _port}, record} -> record end)
        |> Enum.sort_by(fn record -> {-record.count, -record.timestamp} end)
    end
  end

  @spec clear_connect_failed(String.t() | charlist(), non_neg_integer()) :: :ok
  def clear_connect_failed(host, port) do
    case :ets.whereis(:connect_failed) do
      :undefined ->
        :ok

      _table ->
        :ets.delete(:connect_failed, {host, port})
        :ok
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(_init_arg) do
    last_id = all_conditions() |> Enum.max_by(& &1.id, fn -> %{id: 0} end) |> Map.get(:id)
    Logger.info("ConditionManager started.")
    {:ok, %{next_id: last_id + 1}}
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
end
