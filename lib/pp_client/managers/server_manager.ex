defmodule PpClient.ServerManager do
  @moduledoc """
  Proxy Server Manager

  Manages the named upstream servers in an ETS table with the following
  structure:
    {name, server(%ProxyServer{})}

  Profiles refer to servers by name, so this table is the one place a server is
  defined. `fetch_many/1` is the read side the connect path calls just before it
  dials — resolving there rather than when a profile is stored is what makes an
  edit here take effect on the very next connection.

  A server a profile still refers to cannot be deleted; `references/1` reports
  which profiles are in the way.
  """
  use GenServer
  require Logger
  alias PpClient.{ProfileManager, ProxyServer}

  @table :servers

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec all_servers() :: [ProxyServer.t()]
  def all_servers do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, server} -> server end)
    |> Enum.sort_by(& &1.name)
  end

  @spec get_server(String.t()) :: {:ok, ProxyServer.t()} | {:error, :not_found}
  def get_server(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, server}] -> {:ok, server}
      [] -> {:error, :not_found}
    end
  end

  @spec enabled_servers() :: [ProxyServer.t()]
  def enabled_servers do
    Enum.filter(all_servers(), & &1.enable)
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(name) when is_binary(name) do
    match?({:ok, _server}, get_server(name))
  end

  @spec add_server(ProxyServer.t()) :: {:ok, ProxyServer.t()} | {:error, term()}
  def add_server(%ProxyServer{} = server) do
    GenServer.call(__MODULE__, {:add_server, server})
  end

  @spec update_server(ProxyServer.t()) :: {:ok, ProxyServer.t()} | {:error, term()}
  def update_server(%ProxyServer{} = server) do
    GenServer.call(__MODULE__, {:update_server, server})
  end

  @spec delete_server(String.t()) ::
          :ok | {:error, :not_found} | {:error, {:in_use, [String.t()]}}
  def delete_server(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:delete_server, name})
  end

  @spec enable_server(String.t()) :: {:ok, ProxyServer.t()} | {:error, :not_found}
  def enable_server(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:set_enable, name, true})
  end

  @spec disable_server(String.t()) :: {:ok, ProxyServer.t()} | {:error, :not_found}
  def disable_server(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:set_enable, name, false})
  end

  ## Read side used on the connect path

  @doc """
  The servers behind a profile's list of names.

  A name with nothing behind it is dropped rather than raising: the caller is
  about to pick one server out of the list anyway, and an empty result is a case
  it already handles — the route is skipped and the next condition gets a chance.
  """
  @spec fetch_many([String.t()]) :: [ProxyServer.t()]
  def fetch_many(names) when is_list(names) do
    Enum.flat_map(names, fn name ->
      case get_server(name) do
        {:ok, server} -> [server]
        {:error, :not_found} -> []
      end
    end)
  end

  @doc """
  The names of the profiles referring to `name`.
  """
  @spec references(String.t()) :: [String.t()]
  def references(name) when is_binary(name) do
    ProfileManager.all_profiles()
    |> Enum.filter(&(name in &1.servers))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  ## GenServer Callbacks

  @impl true
  def init(_init_arg) do
    Logger.info("ServerManager started.")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_server, %{name: name} = server}, _from, state) do
    with {:ok, validated_server} <- ProxyServer.validate(server),
         true <- :ets.insert_new(@table, {validated_server.name, validated_server}) do
      Logger.info("Added server '#{validated_server.name}'")
      {:reply, {:ok, validated_server}, state}
    else
      false ->
        Logger.error("Failed to add server '#{name}': already exists")
        {:reply, {:error, :already_exists}, state}

      {:error, reason} ->
        Logger.error("Failed to add server '#{name}': #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:update_server, %{name: name} = server}, _from, state) do
    with {:ok, validated_server} <- ProxyServer.validate(server),
         key = validated_server.name,
         [{^key, _old_server}] <- :ets.lookup(@table, key) do
      :ets.insert(@table, {key, validated_server})
      Logger.info("Updated server '#{key}'")
      {:reply, {:ok, validated_server}, state}
    else
      [] ->
        Logger.warning("Server '#{name}' not found for update")
        {:reply, {:error, :not_found}, state}

      {:error, reason} ->
        Logger.error("Failed to update server '#{name}': #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_server, name}, _from, state) do
    case :ets.lookup(@table, name) do
      [{^name, _server}] ->
        case references(name) do
          [] ->
            :ets.delete(@table, name)
            Logger.info("Deleted server '#{name}'")
            {:reply, :ok, state}

          profiles ->
            Logger.warning("Server '#{name}' still used by #{Enum.join(profiles, ", ")}")
            {:reply, {:error, {:in_use, profiles}}, state}
        end

      [] ->
        Logger.warning("Server '#{name}' not found for deletion")
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:set_enable, name, enable}, _from, state) do
    case :ets.lookup(@table, name) do
      [{^name, server}] ->
        updated_server = %{server | enable: enable}
        :ets.insert(@table, {name, updated_server})
        Logger.info("#{if enable, do: "Enabled", else: "Disabled"} server '#{name}'")
        {:reply, {:ok, updated_server}, state}

      [] ->
        Logger.warning("Server '#{name}' not found for enabling/disabling")
        {:reply, {:error, :not_found}, state}
    end
  end
end
