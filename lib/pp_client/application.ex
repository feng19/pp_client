defmodule PpClient.Application do
  @moduledoc false
  use Application
  require Logger
  alias PpClient.{Condition, DnsRecord, Endpoint, ProxyProfile, ProxyServer}

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
    :ets.new(:profiles, [:set, :public, :named_table, {:read_concurrency, true}])
    :ets.new(:conditions, [:set, :public, :named_table, {:read_concurrency, true}])
    :ets.new(:connect_failed, [:set, :public, :named_table, {:read_concurrency, true}])
    :ets.new(:dns_records, [:set, :public, :named_table, {:read_concurrency, true}])
  end

  def load_config, do: load_config(@config_filename)

  def load_config(filename) do
    if File.exists?(filename) do
      {config, _} = Code.eval_file(filename)
      load_endpoints(config)
      load_profiles(config)
      load_conditions(config)
      load_dns_records(config)
      config
    else
      Logger.warning("NOT found the #{filename}")
      %{}
    end
  end

  defp load_endpoints(config) do
    (config[:endpoints] || [])
    |> Stream.map(&Endpoint.new/1)
    |> Enum.map(&{&1.port, &1})
    |> then(&:ets.insert(:endpoints, &1))
  end

  defp load_profiles(config) do
    server_mapping = Map.new(config[:servers] || [], &{elem(&1, 0), ProxyServer.new(elem(&1, 1))})

    (config[:profiles] || [])
    |> Stream.map(fn profile = %{servers: servers} ->
      servers = Enum.map(servers, &Map.fetch!(server_mapping, &1))
      ProxyProfile.new(%{profile | servers: servers})
    end)
    |> Enum.map(&{&1.name, &1})
    |> then(&:ets.insert(:profiles, &1))
  end

  defp load_conditions(config) do
    (config[:conditions] || "")
    |> Condition.parse_conditions()
    |> Enum.map(&{&1.id, &1})
    |> then(&:ets.insert(:conditions, &1))
  end

  defp load_dns_records(config) do
    (config[:dns] || [])
    |> Stream.map(&DnsRecord.new/1)
    |> Enum.map(&{&1.domain, &1})
    |> then(&:ets.insert(:dns_records, &1))
  end
end
