defmodule PpClient.AutoSwitchClient do
  @moduledoc """
  Auto Switch Client
  """
  alias PpClient.{Cache, DirectClient, Socks5Client, WSClient}

  def start_link(target, _opts, parent \\ self()) do
    case route(target) do
      {:direct, _} ->
        {:ok, pid} = DirectClient.start_link(target, parent)
        {:ok, {DirectClient, pid}}

      {:remote, %{client_type: :ws} = server} ->
        {:ok, ws_client} = WSClient.start_link(target, server, parent)
        {:ok, {WSClient, ws_client}}

      {:remote, %{client_type: :socks5} = server} ->
        {:ok, ws_client} = Socks5Client.start_link(target, server, parent)
        {:ok, {WSClient, ws_client}}
    end
  end

  def route({_type, host, _port}) do
    Cache.condition_stream()
    |> Enum.find_value(fn {_, regex, type, servers} ->
      if Regex.match?(regex, host) do
        {type, Enum.random(servers)}
      end
    end)
  end

  def send({DirectClient, pid}, data), do: DirectClient.send(pid, data)
  def send({WSClient, ws_client}, data), do: WSClient.send(ws_client, data)
end
