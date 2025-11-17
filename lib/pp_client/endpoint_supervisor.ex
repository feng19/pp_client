defmodule PpClient.EndpointSupervisor do
  use Supervisor
  require Logger
  alias PpClient.{Endpoint, EndpointManager}

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = EndpointManager.enabled_endpoints() |> Enum.map(&{Endpoint, &1})
    Supervisor.init(children, strategy: :one_for_one)
  end
end
