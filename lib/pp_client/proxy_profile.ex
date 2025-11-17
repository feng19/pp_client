defmodule PpClient.ProxyProfile do
  @moduledoc """
  代理配置文件结构
  """
  defstruct [:name, :type, :enabled, :servers]

  @type t :: %__MODULE__{
          name: String.t(),
          type: :direct | :remote,
          enabled: boolean(),
          servers: [PpClient.ProxyServer.t()]
        }

  def direct(name \\ "direct") do
    %__MODULE__{name: name, type: :direct, enabled: true}
  end

  def remote(name, servers) do
    %__MODULE__{name: name, type: :remote, enabled: true, servers: servers}
  end

  @doc """
  验证代理配置文件
  """
  def validate(%__MODULE__{type: :direct} = profile), do: {:ok, profile}

  def validate(%__MODULE__{type: :remote, servers: servers} = profile) do
    if is_list(servers) and servers != [] do
      {:ok, profile}
    else
      {:error, "Remote proxy profile must have at least one server"}
    end
  end
end
