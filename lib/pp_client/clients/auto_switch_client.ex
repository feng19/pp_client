defmodule PpClient.AutoSwitchClient do
  @moduledoc """
  Auto Switch Client
  """
  alias PpClient.{Cache, DirectClient, ProfileManager, Socks5Client, WSClient}

  def start_link(target, _opts, parent \\ self())

  def start_link(target, [], parent) do
    target |> route() |> do_start_link(target, parent)
  end

  def start_link(target, opts, parent) do
    %{profile: profile_name} = Map.new(opts)

    case ProfileManager.get_profile(profile_name) do
      {:ok, %{enabled: true, type: :direct}} ->
        :direct

      {:ok, %{enabled: true, servers: servers}} ->
        server = Enum.random(servers)
        {server.client_type, [{:type, server.type} | server.opts]}
    end
    |> do_start_link(target, parent)
  end

  defp do_start_link(:direct, target, parent) do
    {:ok, pid} = DirectClient.start_link(target, parent)
    {:ok, {DirectClient, pid}}
  end

  defp do_start_link({:ws, setting}, target, parent) do
    {:ok, ws_client} = WSClient.start_link(target, setting, parent)
    {:ok, {WSClient, ws_client}}
  end

  defp do_start_link({:socks5, setting}, target, parent) do
    {:ok, ws_client} = Socks5Client.start_link(target, setting, parent)
    {:ok, {Socks5Client, ws_client}}
  end

  def route({_type, host, _port}), do: route(host)

  def route(host) do
    Cache.conditions()
    |> Enum.find_value(fn
      {:all, :direct, _} ->
        :direct

      {regex, _type, servers} ->
        if Regex.match?(regex, host) do
          server = Enum.random(servers)
          {server.client_type, [{:type, server.type} | server.opts]}
        end
    end)
    |> Kernel.||(:direct)
  end

  def send({DirectClient, pid}, data), do: DirectClient.send(pid, data)
  def send({WSClient, ws_client}, data), do: WSClient.send(ws_client, data)
  def send({Socks5Client, ws_client}, data), do: Socks5Client.send(ws_client, data)
end
