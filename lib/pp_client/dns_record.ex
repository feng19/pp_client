defmodule PpClient.DnsRecord do
  @moduledoc """
  DNS record struct

  A hand-maintained `domain -> ip` override, consulted before an upstream
  server connection is dialled. Records come from the `:dns` key of `pp.exs`
  and from the admin page; nothing here resolves anything on its own, so a
  domain without a record keeps going out to the system resolver exactly as
  before.
  """

  @enforce_keys [:domain, :ip]
  defstruct domain: nil, ip: nil, enable: true

  @type t :: %__MODULE__{
          domain: String.t(),
          ip: :inet.ip_address(),
          enable: boolean()
        }

  @doc """
  Builds a record from a map or keyword list.

  The domain is downcased — it doubles as the ETS key and hostnames are
  case-insensitive — and the IP is normalised to the tuple form
  `:gen_tcp.connect/4` wants, so both `"1.2.3.4"` and `{1, 2, 3, 4}` are
  accepted.
  """
  @spec new(map() | Keyword.t()) :: t()
  def new(opts) do
    __MODULE__
    |> struct!(opts)
    |> normalize()
    |> validate!()
  end

  @spec validate!(t()) :: t()
  def validate!(record) do
    case validate(record) do
      {:ok, record} -> record
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{domain: domain, ip: ip} = record) do
    cond do
      not is_binary(domain) or domain == "" ->
        {:error, "DNS record must have a domain"}

      not ip?(ip) ->
        {:error, "DNS record for '#{domain}' has an invalid IP: #{inspect(ip)}"}

      true ->
        {:ok, record}
    end
  end

  @doc """
  Normalises the domain and IP without validating, so a bad value survives
  long enough for `validate/1` to name it.
  """
  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{domain: domain, ip: ip} = record) do
    %{record | domain: normalize_domain(domain), ip: parse_ip(ip)}
  end

  @doc """
  Renders the IP the way it is typed in — `"1.2.3.4"`, `"::1"`.
  """
  @spec format_ip(:inet.ip_address() | String.t()) :: String.t()
  def format_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, :einval} -> inspect(ip)
      charlist -> List.to_string(charlist)
    end
  end

  def format_ip(ip) when is_binary(ip), do: ip

  defp normalize_domain(domain) when is_binary(domain) do
    domain |> String.trim() |> String.downcase()
  end

  defp normalize_domain(domain), do: domain

  defp parse_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> tuple
      # Left as it came in; validate/1 turns it into a message naming the domain.
      {:error, :einval} -> ip
    end
  end

  defp parse_ip(ip), do: ip

  defp ip?(ip) when is_tuple(ip), do: :inet.ntoa(ip) != {:error, :einval}
  defp ip?(_ip), do: false
end
