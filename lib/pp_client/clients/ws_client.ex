defmodule PpClient.WSClient do
  @moduledoc false
  use Wind.Client
  alias Plug.Crypto.MessageEncryptor

  @sign_secret "90de3456asxdfrtg"
  @domain 0x03

  def start_link(target, %{servers: servers}, parent) do
    server = Enum.random(servers)
    start_link(target, [{:type, server.type} | server.opts], parent)
  end

  def start_link(target, setting, parent) when is_list(setting) do
    start_link(target, Map.new(setting), parent)
  end

  def start_link(target, setting, parent) when is_map(setting) do
    first_frame = get_first_frame_by_type(setting, target)
    headers = get_headers_by_type(setting, target)

    uri =
      case setting.uri do
        uri when is_binary(uri) -> URI.parse(uri)
        uri = %URI{} -> uri
      end

    Wind.Client.start_link(__MODULE__,
      uri: uri,
      headers: headers,
      pp: %{setting: setting, first_frame: first_frame, parent: parent}
    )
  end

  def send(pid, data) do
    Wind.Client.send(pid, {:binary, data})
  end

  @impl true
  def handle_connect(state) do
    %{first_frame: first_frame, parent: parent} = Keyword.fetch!(state.opts, :pp)
    GenServer.cast(parent, :connected)

    if first_frame do
      {:reply, first_frame, state}
    else
      {:noreply, state}
    end
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

  defp get_first_frame_by_type(
         %{type: "exps", encrypt_type: encrypt_type, encrypt_key: key},
         {_type, hostname, port}
       ) do
    len = byte_size(hostname)
    target_binary = <<@domain, port::16, len, hostname::binary-size(len)>>

    data =
      case encrypt_type do
        :none -> target_binary
        :once -> MessageEncryptor.encrypt(target_binary, key, @sign_secret)
      end

    {:binary, data}
  end

  defp get_first_frame_by_type(_, _), do: nil

  defp get_headers_by_type(%{type: "cf-workers", password: password}, {_type, hostname, port}) do
    target = Enum.join([hostname, port], ":")
    [{"Authorization", password}, {"X-Proxy-Target", target}]
  end

  defp get_headers_by_type(_, _), do: []
end
