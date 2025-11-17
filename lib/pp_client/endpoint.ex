defmodule PpClient.Endpoint do
  @moduledoc """
  Endpoint 结构体，表示一个代理服务端点配置。

  ## 字段说明

  - `:enable` - 是否启用该端点
  - `:type` - 端点类型，支持 `:socks5`, `:http`, `:auto`, `:http_to_socks5`
  - `:ip` - 监听的 IP 地址，元组格式如 `{127, 0, 0, 1}`
  - `:port` - 监听端口号
  - `:options` - 额外的处理器选项列表

  ## 示例

      iex> PpClient.Endpoint.new(%{port: 1080, type: :socks5})
      %PpClient.Endpoint{
        enable: true,
        type: :socks5,
        ip: {127, 0, 0, 1},
        port: 1080,
        options: []
      }
  """

  defstruct enable: true,
            type: :socks5,
            ip: {127, 0, 0, 1},
            port: 1080,
            options: []

  @type endpoint_type :: :socks5 | :http | :auto | :http_to_socks5
  @type ip_address :: :inet.ip_address()

  @type t :: %__MODULE__{
          enable: boolean(),
          type: endpoint_type(),
          ip: ip_address(),
          port: :inet.port_number(),
          options: keyword()
        }

  @spec new(map() | Keyword.t()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end

  def child_id(%__MODULE__{port: port}), do: {ThousandIsland, port}
  def child_id(port), do: {ThousandIsland, port}

  def child_spec(%__MODULE__{type: type, ip: ip, port: port, options: options}) do
    handler =
      case type do
        :socks5 -> PpClient.Socks5
        :http -> PpClient.Http
        :auto -> PpClient.AutoDetect
        :http_to_socks5 -> PpClient.HttpToSocks5
      end

    ThousandIsland.child_spec(
      transport_options: [ip: ip],
      port: port,
      handler_module: handler,
      handler_options: options
    )
    |> Map.put(:id, child_id(port))
  end
end
