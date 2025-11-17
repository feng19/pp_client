defmodule PpClient.ProxyProfile do
  @moduledoc """
  代理配置文件结构
  """
  alias PpClient.ProxyServer

  @enforce_keys [:name, :type, :servers]
  defstruct name: nil, type: nil, enabled: true, servers: []

  @type t :: %__MODULE__{
          name: String.t(),
          type: :direct | :remote,
          enabled: boolean(),
          servers: [ProxyServer.t()]
        }

  def direct(name \\ "direct") do
    %__MODULE__{name: name, type: :direct, enabled: true, servers: []}
  end

  def remote(name, servers) when is_list(servers) do
    %__MODULE__{name: name, type: :remote, enabled: true, servers: servers}
  end

  def new(opts) do
    struct!(__MODULE__, opts) |> validate!()
  end

  def validate!(profile) do
    case validate(profile) do
      {:ok, profile} -> profile
      {:error, reason} -> raise reason
    end
  end

  def validate(%__MODULE__{type: :direct} = profile), do: {:ok, profile}

  def validate(%__MODULE__{type: :remote, servers: servers} = profile) do
    if is_list(servers) and servers != [] do
      if Enum.all?(servers, &is_struct(&1, ProxyServer)) do
        {:ok, profile}
      else
        {:error, "Some of profile's server incorrect"}
      end
    else
      {:error, "Remote profile must have at least one server"}
    end
  end
end
