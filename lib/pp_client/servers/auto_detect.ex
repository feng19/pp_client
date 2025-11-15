defmodule PpClient.AutoDetect do
  @moduledoc false
  use ThousandIsland.Handler
  require Logger
  alias PpClient.{Http, Socks5}

  @impl ThousandIsland.Handler
  def handle_connection(_socket, opts) do
    Process.flag(:trap_exit, true)
    {:continue, {:wait_first, opts}}
  end

  @impl ThousandIsland.Handler
  for method <- ~w"CONNECT GET POST OPTIONS HEAD PUT DELETE TRACE PATCH" do
    def handle_data(<<unquote(method), _rest::binary>> = request, socket, {:wait_first, opts}) do
      set_type_module(Http)
      Http.handle_data(request, socket, {:wait_first, opts})
    end
  end

  def handle_data(<<5, _rest::binary>> = request, socket, {:wait_first, opts}) do
    set_type_module(Socks5)
    Socks5.handle_data(request, socket, {:wait_first, opts})
  end

  def handle_data(<<5, _rest::binary>> = request, socket, {:wait_second, opts}) do
    Socks5.handle_data(request, socket, {:wait_second, opts})
  end

  def handle_data(_request, _socket, {:wait_first, _opts}) do
    {:close, nil}
  end

  def handle_data(data, _socket, {:connected, ws_client} = state) do
    PpClient.WSClient.send(ws_client, data)
    {:continue, state}
  end

  def handle_data(request, socket, state) do
    if module = get_type_module() do
      module.handle_data(request, socket, state)
    else
      {:close, nil}
    end
  end

  @impl GenServer
  def handle_cast(info, {socket, state}) do
    if module = get_type_module() do
      module.handle_cast(info, {socket, state})
    else
      {:close, nil}
    end
  end

  @impl GenServer
  def handle_info({:EXIT, _, _}, {socket, state}) do
    {:stop, :normal, {socket, state}}
  end

  defp set_type_module(module) do
    Process.put(:type_module, module)
  end

  defp get_type_module do
    Process.get(:type_module)
  end
end
