defmodule PpClient.EndpointSupervisor do
  use Supervisor
  require Logger
  alias PpClient.Endpoint

  if Mix.env() == :test do
    @config_filename "pp_config_.exs"
  else
    @config_filename "pp_config_test.exs"
  end

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = load_endpoints_from_config()
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp load_endpoints_from_config do
    if File.exists?(@config_filename) do
      {endpoints, _} = Code.eval_file(@config_filename)
      endpoints
    else
      Logger.warning("NOT found the pp_config.exs")
      []
    end
    |> child_specs()
  end

  defp child_specs(endpoints) do
    endpoints
    |> Stream.map(&Endpoint.new/1)
    |> Stream.uniq_by(& &1.port)
    |> Stream.map(fn endpoint ->
      :ets.insert(:endpoints, {endpoint.port, endpoint})
      endpoint
    end)
    |> Enum.reduce([], fn
      %{enable: false}, acc -> acc
      endpoint, acc -> [{Endpoint, endpoint} | acc]
    end)
  end
end
