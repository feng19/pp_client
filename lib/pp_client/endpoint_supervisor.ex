defmodule PpClient.EndpointSupervisor do
  use Supervisor
  alias PpClient.Endpoint

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = load_endpoints_from_config()
    Supervisor.init(children, strategy: :one_for_one)
  end

  if Mix.env() == :test do
    defp load_endpoints_from_config, do: []
  else
    defp load_endpoints_from_config do
      #      if File.exists?("pp_config.exs") do
      #        {endpoints, _} = Code.eval_file("pp_config.exs")
      #        endpoints
      #      else
      #        Logger.warning("NOT found the pp_config.exs")
      #        []
      #      end
      #      |> child_specs()
      []
    end
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
