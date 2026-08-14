defmodule PpClient.Schemas.ServerSchema do
  @moduledoc """
  Schema for Server form validation and conversion

  The form is flat — `uri`, `host`, `port` and the credentials sit next to each
  other and only the ones the chosen type needs are validated — while
  `PpClient.ProxyServer` keeps them under `opts`. `to_proxy_server/1` and
  `from_proxy_server/1` are the two sides of that translation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PpClient.ProxyServer

  # Kept usable as an atom key, so a server set up in the admin UI can be copied
  # straight into the `servers:` section of pp.exs.
  @name_format ~r/^[A-Za-z0-9_-]+$/

  @primary_key false
  embedded_schema do
    field :name, :string
    field :type, :string
    field :enable, :boolean, default: true
    field :uri, :string
    field :host, :string
    field :port, :integer
    # This struct and the changesets built from it are carried in LiveView
    # assigns, which are written to the log whole when the process crashes.
    # `redact: true` covers the struct, plus a changeset's `changes` and `data`.
    field :password, :string, redact: true
    field :encrypt_type, Ecto.Enum, values: [:none, :once], default: :none
    field :encrypt_key, :string, redact: true
  end

  @doc """
  Changeset for server validation
  """
  def changeset(schema, attrs \\ %{}) do
    schema
    |> cast(attrs, [
      :name,
      :type,
      :enable,
      :uri,
      :host,
      :port,
      :password,
      :encrypt_type,
      :encrypt_key
    ])
    |> validate_required([:name, :type])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_format(:name, @name_format,
      message: "may only contain letters, numbers, underscores and dashes"
    )
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
  Convert ServerSchema to ProxyServer struct
  """
  def to_proxy_server(%__MODULE__{} = schema) do
    opts =
      case schema.type do
        "exps" ->
          %{
            uri: schema.uri,
            encrypt_type: schema.encrypt_type || :none,
            encrypt_key: schema.encrypt_key
          }

        "cf-workers" ->
          %{
            uri: schema.uri,
            password: schema.password
          }

        "socks5" ->
          %{
            host: schema.host,
            port: schema.port
          }

        _ ->
          %{}
      end

    client_type =
      case schema.type do
        "socks5" -> :socks5
        _ -> :ws
      end

    %ProxyServer{
      name: schema.name,
      type: schema.type,
      client_type: client_type,
      enable: schema.enable,
      opts: opts
    }
  end

  @doc """
  Convert ProxyServer to ServerSchema
  """
  def from_proxy_server(%ProxyServer{} = server) do
    base = %{
      name: server.name,
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

    struct!(__MODULE__, Map.merge(base, fields))
  end
end
