defmodule PpClient.Schemas.EndpointSchema do
  @moduledoc """
  Ecto Schema for Endpoint validation and form handling.
  This is separate from the PpClient.Endpoint struct to provide
  Ecto changeset functionality for web forms.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type_options [:socks5, :http, :auto, :http_to_socks5]

  @primary_key false
  embedded_schema do
    field :port, :integer
    field :type, Ecto.Enum, values: @type_options
    field :ip, :string
    field :enable, :boolean, default: true
  end

  @doc """
  Creates a changeset for endpoint validation.
  """
  def changeset(endpoint, attrs \\ %{}) do
    endpoint
    |> cast(attrs, [:port, :type, :ip, :enable])
    |> validate_required([:port, :type, :ip])
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65535)
    |> validate_ip_format()
    |> validate_inclusion(:type, @type_options)
  end

  @doc """
  Converts the schema to a PpClient.Endpoint struct.
  """
  def to_endpoint(%__MODULE__{} = schema) do
    %PpClient.Endpoint{
      port: schema.port,
      type: schema.type,
      ip: parse_ip(schema.ip),
      enable: schema.enable,
      options: []
    }
  end

  @doc """
  Creates a schema from a PpClient.Endpoint struct.
  """
  def from_endpoint(%PpClient.Endpoint{} = endpoint) do
    %__MODULE__{
      port: endpoint.port,
      type: endpoint.type,
      ip: format_ip(endpoint.ip),
      enable: endpoint.enable
    }
  end

  defp validate_ip_format(changeset) do
    validate_change(changeset, :ip, fn :ip, ip_string ->
      case parse_ip(ip_string) do
        {:error, _} -> [ip: "invalid IP address format"]
        _ -> []
      end
    end)
  end

  defp parse_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} -> ip_tuple
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_ip(ip_tuple) when is_tuple(ip_tuple), do: ip_tuple

  defp format_ip(ip_tuple) when is_tuple(ip_tuple) do
    ip_tuple
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp format_ip(ip_string) when is_binary(ip_string), do: ip_string
end
