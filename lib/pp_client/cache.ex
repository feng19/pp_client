defmodule PpClient.Cache do
  @moduledoc """
  Cache

  Caches all enabled conditions and maps profiles to servers.

  Cache structure: `{condition_pattern, profile_type, servers}`
  where:
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

  @spec conditions() :: Enumerable.t()
  def conditions do
    case :ets.lookup(@table, :conditions) do
      [{_, conditions}] -> conditions
      _ -> []
    end
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
      Enum.reduce(enabled_conditions, [], fn condition, acc ->
        case ProfileManager.get_profile(condition.profile_name) do
          {:ok, %{enabled: true, type: type, servers: servers}} ->
            # Only cache if the profile is also enabled
            [{condition.condition, type, servers} | acc]

          {:ok, _profile} ->
            acc

          {:error, :not_found} ->
            Logger.warning(
              "Skipping condition #{condition.id}: profile '#{condition.profile_name}' not found"
            )

            acc
        end
      end)
      |> Enum.reverse()

    # Insert all cache entries
    :ets.insert(@table, {:conditions, cache_entries})

    Logger.info("Cache refreshed with #{length(cache_entries)} entries")
    :ok
  end
end
