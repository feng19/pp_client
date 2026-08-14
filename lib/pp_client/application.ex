defmodule PpClient.Application do
  @moduledoc false
  use Application
  require Logger
  alias PpClient.Config

  @supervisor PpClient.Supervisor
  if Mix.env() == :test do
    @config_filename "pp_test.exs"
  else
    @config_filename "pp.exs"
  end

  @impl true
  def start(_type, _args) do
    init_ets_tables()
    config = load_config(@config_filename)
    web_opts = config[:web] || []

    web_children =
      if web_opts[:server] do
        [
          PpClientWeb.Telemetry,
          {Phoenix.PubSub, name: PpClient.PubSub},
          # Start to serve requests, typically the last entry
          {PpClientWeb.Endpoint, Enum.to_list(web_opts)}
        ]
      else
        Application.stop(:phoenix)
        []
      end

    children =
      [
        PpClient.ServerManager,
        PpClient.ProfileManager,
        PpClient.ConditionManager,
        PpClient.DnsRecordManager,
        PpClient.EndpointManager,
        PpClient.Cache
      ] ++ web_children ++ [PpClient.EndpointSupervisor]

    Supervisor.start_link(children, strategy: :one_for_one, name: @supervisor)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PpClientWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp init_ets_tables do
    :ets.new(:endpoints, [:set, :public, :named_table])
    :ets.new(:pp_cache, [:set, :public, :named_table, {:read_concurrency, true}])
    :ets.new(:servers, [:set, :public, :named_table, {:read_concurrency, true}])
    :ets.new(:profiles, [:set, :public, :named_table, {:read_concurrency, true}])
    :ets.new(:conditions, [:set, :public, :named_table, {:read_concurrency, true}])
    :ets.new(:connect_failed, [:set, :public, :named_table, {:read_concurrency, true}])
    :ets.new(:dns_records, [:set, :public, :named_table, {:read_concurrency, true}])
  end

  def load_config, do: load_config(@config_filename)

  @doc """
  Reads a config file into the runtime tables and returns it.

  The boot path, and the one place the filename is resolved — it is relative, so
  it comes out of the directory the client was started from. A missing file is
  not an error: every section is optional, and a client with no config file at
  all is one that proxies nothing yet.

  `PpClient.Config` does the work, and is also where a config that arrives some
  other way — an import from the admin UI — goes in.
  """
  def load_config(filename) do
    if File.exists?(filename) do
      {config, _} = Code.eval_file(filename)
      Config.load!(config)
      config
    else
      Logger.warning("NOT found the #{filename}")
      %{}
    end
  end
end
