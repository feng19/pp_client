defmodule PpClient.DnsRecordManager do
  @moduledoc """
  DNS Record Manager

  Manages hand-maintained `domain -> ip` overrides in an ETS table with the
  following structure:
    {domain, record(%DnsRecord{})}

  `lookup/1`, `address/1` and `dial/2` are the read side the upstream clients
  call just before they dial; the rest is the CRUD the admin page drives.
  Nothing in here queries a name server — a domain with no enabled record is
  reported as a miss and the caller hands the hostname to the system resolver
  as it always did.
  """
  use GenServer
  require Logger
  alias PpClient.DnsRecord

  @table :dns_records

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec all_records() :: [DnsRecord.t()]
  def all_records do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_domain, record} -> record end)
    |> Enum.sort_by(& &1.domain)
  end

  @spec get_record(String.t()) :: {:ok, DnsRecord.t()} | {:error, :not_found}
  def get_record(domain) when is_binary(domain) do
    key = normalize_domain(domain)

    case :ets.lookup(@table, key) do
      [{^key, record}] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(domain) when is_binary(domain) do
    case get_record(domain) do
      {:ok, _record} -> true
      {:error, :not_found} -> false
    end
  end

  @spec add_record(DnsRecord.t()) :: {:ok, DnsRecord.t()} | {:error, term()}
  def add_record(%DnsRecord{} = record) do
    GenServer.call(__MODULE__, {:add_record, record})
  end

  @spec update_record(DnsRecord.t()) :: {:ok, DnsRecord.t()} | {:error, term()}
  def update_record(%DnsRecord{} = record) do
    GenServer.call(__MODULE__, {:update_record, record})
  end

  @spec delete_record(String.t()) :: :ok | {:error, :not_found}
  def delete_record(domain) when is_binary(domain) do
    GenServer.call(__MODULE__, {:delete_record, normalize_domain(domain)})
  end

  @spec enable_record(String.t()) :: {:ok, DnsRecord.t()} | {:error, :not_found}
  def enable_record(domain) when is_binary(domain) do
    GenServer.call(__MODULE__, {:set_enable, normalize_domain(domain), true})
  end

  @spec disable_record(String.t()) :: {:ok, DnsRecord.t()} | {:error, :not_found}
  def disable_record(domain) when is_binary(domain) do
    GenServer.call(__MODULE__, {:set_enable, normalize_domain(domain), false})
  end

  ## Read side used on the connect path

  @doc """
  The IP an enabled record holds for `host`, if there is one.

  An IP literal is reported as a miss: there is nothing to override, and the
  caller already handles literals.
  """
  @spec lookup(String.t()) :: {:ok, :inet.ip_address()} | :miss
  def lookup(host) when is_binary(host) do
    if ip_literal?(host) do
      :miss
    else
      case enabled_record(host) do
        {:ok, %DnsRecord{ip: ip}} -> {:ok, ip}
        :error -> :miss
      end
    end
  end

  @doc """
  The address to hand `:gen_tcp.connect/4`.

  An IP literal and a record hit both come back as a tuple — `:gen_tcp` infers
  the address family from those, where a charlist literal would need an
  explicit `:inet6` and otherwise fails resolution with `:nxdomain`. Anything
  else stays a charlist and is resolved by the system as before.
  """
  @spec address(String.t()) :: :inet.ip_address() | charlist()
  def address(host) when is_binary(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        ip

      {:error, :einval} ->
        case lookup(host) do
          {:ok, ip} -> ip
          :miss -> charlist
        end
    end
  end

  @doc """
  Rewrites a websocket URI and its `Mint.HTTP.connect/4` options to dial a
  record's IP.

  Mint takes the address from the URI host and everything else — the `Host`
  header, SNI, certificate verification — from `:hostname`, so the domain
  still goes out on the wire. `:inet6` has to be added for an IPv6 record
  because Mint's IPv6 branch is off by default and it reads that flag from the
  transport options.

  Returns the URI and options untouched on a miss.
  """
  @spec dial(URI.t(), keyword()) :: {URI.t(), keyword()}
  def dial(%URI{host: host} = uri, http_opts) when is_binary(host) do
    case lookup(host) do
      {:ok, ip} ->
        dial_uri = %URI{uri | host: DnsRecord.format_ip(ip)}

        http_opts =
          http_opts
          |> Keyword.put(:hostname, host)
          |> put_inet6(ip)

        {dial_uri, http_opts}

      :miss ->
        {uri, http_opts}
    end
  end

  def dial(uri, http_opts), do: {uri, http_opts}

  ## GenServer Callbacks

  @impl true
  def init(_init_arg) do
    Logger.info("DnsRecordManager started.")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_record, %{domain: domain} = record}, _from, state) do
    with {:ok, validated_record} <- validate(record),
         true <- :ets.insert_new(@table, {validated_record.domain, validated_record}) do
      Logger.info("Added DNS record '#{validated_record.domain}'")
      {:reply, {:ok, validated_record}, state}
    else
      false ->
        Logger.error("Failed to add DNS record '#{domain}': already exists")
        {:reply, {:error, :already_exists}, state}

      {:error, reason} ->
        Logger.error("Failed to add DNS record '#{domain}': #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:update_record, %{domain: domain} = record}, _from, state) do
    with {:ok, validated_record} <- validate(record),
         key = validated_record.domain,
         [{^key, _old_record}] <- :ets.lookup(@table, key) do
      :ets.insert(@table, {key, validated_record})
      Logger.info("Updated DNS record '#{key}'")
      {:reply, {:ok, validated_record}, state}
    else
      [] ->
        Logger.warning("DNS record '#{domain}' not found for update")
        {:reply, {:error, :not_found}, state}

      {:error, reason} ->
        Logger.error("Failed to update DNS record '#{domain}': #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_record, domain}, _from, state) do
    case :ets.lookup(@table, domain) do
      [{^domain, _record}] ->
        :ets.delete(@table, domain)
        Logger.info("Deleted DNS record '#{domain}'")
        {:reply, :ok, state}

      [] ->
        Logger.warning("DNS record '#{domain}' not found for deletion")
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:set_enable, domain, enable}, _from, state) do
    case :ets.lookup(@table, domain) do
      [{^domain, record}] ->
        updated_record = %{record | enable: enable}
        :ets.insert(@table, {domain, updated_record})
        Logger.info("#{if enable, do: "Enabled", else: "Disabled"} DNS record '#{domain}'")
        {:reply, {:ok, updated_record}, state}

      [] ->
        Logger.warning("DNS record '#{domain}' not found for enabling/disabling")
        {:reply, {:error, :not_found}, state}
    end
  end

  ## Helpers

  defp validate(record) do
    record |> DnsRecord.normalize() |> DnsRecord.validate()
  end

  defp enabled_record(host) do
    key = normalize_domain(host)

    with tid when tid != :undefined <- :ets.whereis(@table),
         [{^key, %DnsRecord{enable: true} = record}] <- :ets.lookup(tid, key) do
      {:ok, record}
    else
      _other -> :error
    end
  end

  defp normalize_domain(domain), do: domain |> String.trim() |> String.downcase()

  defp ip_literal?(host) do
    match?({:ok, _ip}, :inet.parse_address(String.to_charlist(host)))
  end

  defp put_inet6(http_opts, ip) when tuple_size(ip) == 8 do
    Keyword.update(http_opts, :transport_opts, [inet6: true], &Keyword.put(&1, :inet6, true))
  end

  defp put_inet6(http_opts, _ip), do: http_opts
end
