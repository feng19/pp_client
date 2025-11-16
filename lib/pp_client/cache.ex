defmodule PpClient.Cache do
  @moduledoc """
  Cache

  Caches all enabled conditions and maps profiles to servers.

  Cache structure: `{condition_id, condition_pattern, profile_type, servers}`
  where:
  - `condition_id`: integer ID of the condition
  - `condition_pattern`: the regex pattern from the condition
  - `profile_type`: `:direct` or `:remote`
  - `servers`: list of `PpClient.ProxyServer.t()` structs
  """
  use GenServer
  require Logger

  alias PpClient.{ConditionManager, ProfileManager}

  @table :pp_cache

  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh_cache)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec condition_stream() :: Enumerable.t()
  def condition_stream do
    ets_stream(@table)
  end

  ## GenServer Callbacks

  @impl true
  def init(_init_arg) do
    # Perform initial cache refresh
    refresh_cache_internal()
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:refresh_cache, state) do
    refresh_cache_internal()
    {:noreply, state}
  end

  ## Private Functions

  defp refresh_cache_internal do
    Logger.info("Refreshing cache...")

    # Clear existing cache
    :ets.delete_all_objects(@table)

    # Get all enabled conditions
    enabled_conditions = ConditionManager.enabled_conditions()

    # Build cache entries for each enabled condition
    cache_entries =
      Enum.flat_map(enabled_conditions, fn condition ->
        case ProfileManager.get_profile(condition.profile_name) do
          {:ok, profile} when profile.enabled ->
            # Only cache if the profile is also enabled
            [{condition.id, condition.condition, profile.type, profile.servers}]

          {:ok, _profile} ->
            # Profile exists but is disabled
            Logger.debug(
              "Skipping condition #{condition.id}: profile '#{condition.profile_name}' is disabled"
            )

            []

          {:error, :not_found} ->
            Logger.warning(
              "Skipping condition #{condition.id}: profile '#{condition.profile_name}' not found"
            )

            []
        end
      end)

    # Insert all cache entries
    :ets.insert(@table, cache_entries)

    Logger.info("Cache refreshed with #{length(cache_entries)} entries")
    :ok
  end

  defp ets_stream(table) do
    Stream.unfold(:ets.first(table), fn
      :"$end_of_table" ->
        nil

      key ->
        [record] = :ets.lookup(table, key)
        next_key = :ets.next(table, key)
        {record, next_key}
    end)
  end
end
