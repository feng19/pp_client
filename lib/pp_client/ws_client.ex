defmodule PpClient.WSClient do
  @moduledoc false
  use Wind.Client

  def start_link(%{servers: servers, opts: _opts}, target, parent) do
    # todo servers
    # todo exps
    [%{uri: uri, type: "cf-workers", password: password}] = servers
    {_type, hostname, port} = target
    first_data = ~s|{"hostname":"#{hostname}","port":#{port},"psw":"#{password}"}|
    Wind.Client.start_link(__MODULE__, uri: uri, pp: %{first_data: first_data, parent: parent})
  end

  @impl true
  def handle_connect(state) do
    %{first_data: first_data, parent: parent} = Keyword.fetch!(state.opts, :pp)
    GenServer.cast(parent, :connected)
    {:reply, {:text, first_data}, state}
  end

  @impl true
  def handle_frame({:binary, data}, state) do
    %{parent: parent} = Keyword.fetch!(state.opts, :pp)
    GenServer.cast(parent, {:send, data})
    {:noreply, state}
  end

  def handle_frame({:close, _, _}, state) do
    %{parent: parent} = Keyword.fetch!(state.opts, :pp)
    GenServer.cast(parent, :close)
    {:noreply, state}
  end
end
