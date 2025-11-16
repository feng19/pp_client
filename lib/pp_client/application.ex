defmodule PpClient.Application do
  @moduledoc false
  use Application
  require Logger

  @supervisor PpClient.Supervisor

  @impl true
  def start(_type, _args) do
    init_ets_tables()

    children = [
      PpClientWeb.Telemetry,
      {Phoenix.PubSub, name: PpClient.PubSub},
      PpClient.ProfileManager,
      PpClient.ConditionManager,
      PpClient.EndpointManager,
      PpClient.Cache,
      # Start to serve requests, typically the last entry
      PpClientWeb.Endpoint,
      PpClient.EndpointSupervisor
    ]

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
  end
end
