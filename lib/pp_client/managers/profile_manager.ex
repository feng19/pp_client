defmodule PpClient.ProfileManager do
  @moduledoc """
  Profile Manager

  Manages proxy profiles in an ETS table with the following structure:
    {profile_name, profile(%ProxyProfile{})}

  Provides APIs for CRUD operations and enable/disable functionality.
  """
  use GenServer
  require Logger
  alias PpClient.ProxyProfile

  @table :profiles

  ## Client API

  @doc """
  Starts the ProfileManager GenServer.

  ## Examples

      iex> PpClient.ProfileManager.start_link([])
      {:ok, pid}

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Returns all profiles stored in the ETS table.

  ## Examples

      iex> PpClient.ProfileManager.all_profiles()
      [%PpClient.ProxyProfile{name: "direct", ...}, ...]

  """
  @spec all_profiles() :: [ProxyProfile.t()]
  def all_profiles do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, profile} -> profile end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Returns a profile by its name.

  ## Examples

      iex> PpClient.ProfileManager.get_profile("direct")
      {:ok, %PpClient.ProxyProfile{name: "direct", ...}}

      iex> PpClient.ProfileManager.get_profile("nonexistent")
      {:error, :not_found}

  """
  @spec get_profile(String.t()) :: {:ok, ProxyProfile.t()} | {:error, :not_found}
  def get_profile(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, profile}] -> {:ok, profile}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns all enabled profiles.

  ## Examples

      iex> PpClient.ProfileManager.enabled_profiles()
      [%PpClient.ProxyProfile{name: "proxy1", enabled: true}, ...]

  """
  @spec enabled_profiles() :: [ProxyProfile.t()]
  def enabled_profiles do
    all_profiles()
    |> Enum.filter(& &1.enabled)
  end

  @doc """
  Adds a new profile to the ETS table.

  ## Examples

      iex> profile = %PpClient.ProxyProfile{name: "proxy1", type: :remote, enabled: true, servers: []}
      iex> PpClient.ProfileManager.add_profile(profile)
      {:ok, %PpClient.ProxyProfile{name: "proxy1", ...}}

      iex> PpClient.ProfileManager.add_profile(profile)
      {:error, :already_exists}

  """
  @spec add_profile(ProxyProfile.t()) :: {:ok, ProxyProfile.t()} | {:error, :already_exists}
  def add_profile(%ProxyProfile{name: name} = profile) when not is_nil(name) do
    GenServer.call(__MODULE__, {:add_profile, profile})
  end

  @doc """
  Updates an existing profile in the ETS table.

  ## Examples

      iex> profile = %PpClient.ProxyProfile{name: "proxy1", type: :remote, enabled: false, servers: []}
      iex> PpClient.ProfileManager.update_profile(profile)
      {:ok, %PpClient.ProxyProfile{name: "proxy1", ...}}

      iex> PpClient.ProfileManager.update_profile(%PpClient.ProxyProfile{name: "nonexistent", ...})
      {:error, :not_found}

  """
  @spec update_profile(ProxyProfile.t()) :: {:ok, ProxyProfile.t()} | {:error, :not_found}
  def update_profile(%ProxyProfile{name: name} = profile) when not is_nil(name) do
    GenServer.call(__MODULE__, {:update_profile, profile})
  end

  @doc """
  Deletes a profile from the ETS table by its name.

  ## Examples

      iex> PpClient.ProfileManager.delete_profile("proxy1")
      :ok

      iex> PpClient.ProfileManager.delete_profile("nonexistent")
      {:error, :not_found}

  """
  @spec delete_profile(String.t()) :: :ok | {:error, :not_found}
  def delete_profile(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:delete_profile, name})
  end

  @doc """
  Enables a profile by its name.

  ## Examples

      iex> PpClient.ProfileManager.enable_profile("proxy1")
      {:ok, %PpClient.ProxyProfile{name: "proxy1", enabled: true}}

  """
  @spec enable_profile(String.t()) :: {:ok, ProxyProfile.t()} | {:error, :not_found}
  def enable_profile(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:enable_profile, name})
  end

  @doc """
  Disables a profile by its name.

  ## Examples

      iex> PpClient.ProfileManager.disable_profile("proxy1")
      {:ok, %PpClient.ProxyProfile{name: "proxy1", enabled: false}}

  """
  @spec disable_profile(String.t()) :: {:ok, ProxyProfile.t()} | {:error, :not_found}
  def disable_profile(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:disable_profile, name})
  end

  @doc """
  Checks if a profile exists for the given name.

  ## Examples

      iex> PpClient.ProfileManager.exists?("direct")
      true

      iex> PpClient.ProfileManager.exists?("nonexistent")
      false

  """
  @spec exists?(String.t()) :: boolean()
  def exists?(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, _profile}] -> true
      [] -> false
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(_init_arg) do
    load_profiles_from_config()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_profile, %{name: name} = profile}, _from, state) do
    with {:ok, validated_profile} <- ProxyProfile.validate(profile),
         true <- :ets.insert_new(@table, {name, validated_profile}) do
      Logger.info("Added profile '#{name}'")
      {:reply, {:ok, validated_profile}, state}
    else
      false ->
        Logger.error("Failed to add profile '#{name}': already exists")
        {:reply, {:error, :already_exists}, state}

      {:error, reason} ->
        Logger.error("Failed to add profile '#{name}': #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:update_profile, %{name: name} = profile}, _from, state) do
    with {:ok, validated_profile} <- ProxyProfile.validate(profile),
         [{^name, _old_profile}] <- :ets.lookup(@table, name) do
      :ets.insert(@table, {name, validated_profile})
      Logger.info("Updated profile '#{name}'")
      {:reply, {:ok, validated_profile}, state}
    else
      [] ->
        Logger.warning("Profile '#{name}' not found for update")
        {:reply, {:error, :not_found}, state}

      {:error, reason} ->
        Logger.error("Failed to update profile '#{name}': #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_profile, name}, _from, state) do
    case :ets.lookup(@table, name) do
      [{^name, _profile}] ->
        :ets.delete(@table, name)
        Logger.info("Deleted profile '#{name}'")
        {:reply, :ok, state}

      [] ->
        Logger.warning("Profile '#{name}' not found for deletion")
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:enable_profile, name}, _from, state) do
    case :ets.lookup(@table, name) do
      [{^name, profile}] ->
        updated_profile = %{profile | enabled: true}
        :ets.insert(@table, {name, updated_profile})
        Logger.info("Enabled profile '#{name}'")
        {:reply, {:ok, updated_profile}, state}

      [] ->
        Logger.warning("Profile '#{name}' not found for enabling")
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:disable_profile, name}, _from, state) do
    case :ets.lookup(@table, name) do
      [{^name, profile}] ->
        updated_profile = %{profile | enabled: false}
        :ets.insert(@table, {name, updated_profile})
        Logger.info("Disabled profile '#{name}'")
        {:reply, {:ok, updated_profile}, state}

      [] ->
        Logger.warning("Profile '#{name}' not found for disabling")
        {:reply, {:error, :not_found}, state}
    end
  end

  ## Private Functions

  defp load_profiles_from_config do
    # Load a default "direct" profile
    direct_profile = ProxyProfile.direct()
    :ets.insert(@table, {direct_profile.name, direct_profile})
    Logger.info("Loaded default 'direct' profile")

    # Load additional profiles from config file if it exists
    # This can be extended to load from a profiles config file
    # similar to how EndpointManager loads from pp_config.exs
    :ok
  end
end
