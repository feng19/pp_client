defmodule PpClient.Schemas.ProfileSchema do
  @moduledoc """
  Schema for Profile form validation and conversion
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PpClient.ProxyProfile
  alias PpClient.ProxyServer

  @primary_key false
  embedded_schema do
    field :name, :string
    field :type, Ecto.Enum, values: [:direct, :remote]
    field :enabled, :boolean, default: true

    embeds_many :servers, Server, primary_key: false do
      field :type, :string
      field :enable, :boolean, default: true
      field :uri, :string
      field :host, :string
      field :port, :integer
      field :password, :string
      field :encrypt_type, Ecto.Enum, values: [:none, :once], default: :none
      field :encrypt_key, :string
    end
  end

  @doc """
  Changeset for profile validation
  """
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:name, :type, :enabled])
    |> validate_required([:name, :type])
    |> validate_length(:name, min: 1, max: 100)
    |> cast_embed(:servers, with: &server_changeset/2)
  end

  @doc """
  Changeset for server validation
  """
  def server_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:type, :enable, :uri, :host, :port, :password, :encrypt_type, :encrypt_key])
    |> validate_required([:type])
    |> validate_server_fields()
  end

  defp validate_server_fields(changeset) do
    type = get_field(changeset, :type)

    case type do
      "exps" ->
        changeset
        |> validate_required([:uri])
        |> validate_format(:uri, ~r/^wss?:\/\/.+/, message: "must be a valid WebSocket URL")

      "cf-workers" ->
        changeset
        |> validate_required([:uri, :password])
        |> validate_format(:uri, ~r/^wss?:\/\/.+/, message: "must be a valid WebSocket URL")

      "socks5" ->
        changeset
        |> validate_required([:host, :port])
        |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65535)

      _ ->
        changeset
    end
  end

  @doc """
  Convert ProfileSchema to ProxyProfile struct
  """
  def to_profile(%__MODULE__{} = schema) do
    servers =
      if schema.servers do
        Enum.map(schema.servers, &to_proxy_server/1)
      else
        []
      end

    %ProxyProfile{
      name: schema.name,
      type: schema.type,
      enabled: schema.enabled,
      servers: servers
    }
  end

  defp to_proxy_server(server_schema) do
    opts =
      case server_schema.type do
        "exps" ->
          %{
            uri: server_schema.uri,
            encrypt_type: server_schema.encrypt_type || :none,
            encrypt_key: server_schema.encrypt_key
          }

        "cf-workers" ->
          %{
            uri: server_schema.uri,
            password: server_schema.password
          }

        "socks5" ->
          %{
            host: server_schema.host,
            port: server_schema.port
          }

        _ ->
          %{}
      end

    client_type =
      case server_schema.type do
        "socks5" -> :socks5
        _ -> :ws
      end

    %ProxyServer{
      type: server_schema.type,
      client_type: client_type,
      enable: server_schema.enable,
      opts: opts
    }
  end

  @doc """
  Convert ProxyProfile to ProfileSchema
  """
  def from_profile(%ProxyProfile{} = profile) do
    servers =
      if profile.servers do
        Enum.map(profile.servers, &from_proxy_server/1)
      else
        []
      end

    %__MODULE__{
      name: profile.name,
      type: profile.type,
      enabled: profile.enabled,
      servers: servers
    }
  end

  defp from_proxy_server(%ProxyServer{} = server) do
    base = %{
      type: server.type,
      enable: server.enable
    }

    fields =
      case server.type do
        "exps" ->
          %{
            uri: server.opts[:uri],
            encrypt_type: server.opts[:encrypt_type] || :none,
            encrypt_key: server.opts[:encrypt_key]
          }

        "cf-workers" ->
          %{
            uri: server.opts[:uri],
            password: server.opts[:password]
          }

        "socks5" ->
          %{
            host: server.opts[:host],
            port: server.opts[:port]
          }

        _ ->
          %{}
      end

    Map.merge(base, fields)
  end
end
