defmodule PpClient.Cache do
  @moduledoc """
  Cache

  Caches all enabled conditions.

  Cache structure: `{condition_pattern, profile_name}`
  where:
  - `condition_pattern`: the regex pattern from the condition, or `:all`
  - `profile_name`: the profile that pattern routes to

  Only the link between a pattern and a profile is cached, because that is the
  only part of the decision that is expensive to recompute. The profile, its
  server names and the servers themselves are all resolved when a connection is
  dialled, so editing a profile or a server takes effect on the next connection
  rather than on the next `refresh/0`.

  That matters more than the lookups it costs: a cached route that no longer
  resolves does not fail closed. `AutoSwitchClient.route/1` falls through to
  `:direct`, so a stale entry here would silently send matched traffic
  unproxied.
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

    # A condition naming a profile that does not exist is still cached — it is
    # resolved on the connect path like any other, and skipped there. The warning
    # is only so the mistake is visible to whoever is editing conditions.
    cache_entries =
      Enum.map(enabled_conditions, fn condition ->
        unless ProfileManager.exists?(condition.profile_name) do
          Logger.warning(
            "Condition #{condition.id}: profile '#{condition.profile_name}' not found"
          )
        end

        {condition.condition, condition.profile_name}
      end)

    # Insert all cache entries
    :ets.insert(@table, {:conditions, cache_entries})

    Logger.info("Cache refreshed with #{length(cache_entries)} entries")
    :ok
  end
end
