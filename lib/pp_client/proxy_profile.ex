defmodule PpClient.ProxyProfile do
  @moduledoc """
  Proxy profile struct

  `servers` holds the *names* of `PpClient.ProxyServer`s, not the servers
  themselves — the definitions live in `PpClient.ServerManager` and are resolved
  when a connection is dialled, so an edit to a server takes effect immediately
  for every profile that refers to it.
  """

  @enforce_keys [:name, :type, :servers]
  defstruct name: nil, type: nil, enabled: true, servers: []

  @type t :: %__MODULE__{
          name: String.t(),
          type: :direct | :remote,
          enabled: boolean(),
          servers: [String.t()]
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
    # Only the shape is checked here. Whether the names resolve is enforced where
    # a profile is written — `PpClient.Application.load_profiles/1` for the config
    # file, `PpClient.Schemas.ProfileSchema` for the admin form — because this
    # struct has no business reading the server table.
    if is_list(servers) and servers != [] do
      if Enum.all?(servers, &server_name?/1) do
        {:ok, profile}
      else
        {:error, "Some of profile's server incorrect"}
      end
    else
      {:error, "Remote profile must have at least one server"}
    end
  end

  defp server_name?(name), do: is_binary(name) and name != ""
end
