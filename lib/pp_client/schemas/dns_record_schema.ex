defmodule PpClient.Schemas.DnsRecordSchema do
  @moduledoc """
  Ecto Schema for DNS record validation and form handling.
  This is separate from the PpClient.DnsRecord struct to provide
  Ecto changeset functionality for web forms.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PpClient.DnsRecord

  # A bare hostname: labels of letters, digits and hyphens joined by dots. No
  # scheme, port, path or wildcard — the domain is matched against a connection's
  # hostname exactly.
  @domain_format ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/

  @primary_key false
  embedded_schema do
    field :domain, :string
    field :ip, :string
    field :enable, :boolean, default: true
  end

  @doc """
  Creates a changeset for DNS record validation.
  """
  def changeset(record, attrs \\ %{}) do
    record
    |> cast(attrs, [:domain, :ip, :enable])
    |> update_change(:domain, &normalize_domain/1)
    |> update_change(:ip, &String.trim/1)
    |> validate_required([:domain, :ip])
    |> validate_length(:domain, max: 253)
    |> validate_format(:domain, @domain_format,
      message: "must be a bare hostname, without scheme, port or path"
    )
    |> validate_ip_format()
  end

  @doc """
  Converts the schema to a PpClient.DnsRecord struct.
  """
  def to_dns_record(%__MODULE__{} = schema) do
    DnsRecord.new(%{domain: schema.domain, ip: schema.ip, enable: schema.enable})
  end

  @doc """
  Creates a schema from a PpClient.DnsRecord struct.
  """
  def from_dns_record(%DnsRecord{} = record) do
    %__MODULE__{
      domain: record.domain,
      ip: DnsRecord.format_ip(record.ip),
      enable: record.enable
    }
  end

  defp normalize_domain(domain), do: domain |> String.trim() |> String.downcase()

  defp validate_ip_format(changeset) do
    validate_change(changeset, :ip, fn :ip, ip_string ->
      case :inet.parse_address(String.to_charlist(ip_string)) do
        {:ok, _ip_tuple} -> []
        {:error, :einval} -> [ip: "invalid IP address format"]
      end
    end)
  end
end
