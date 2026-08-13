defmodule PpClient.DirectClient do
  @moduledoc """
  Direct Client

  `connect/2` runs in the caller's process, so the caller ends up owning the
  socket and relays both directions itself — see `PpClient.Relay`.
  """
  require Logger
  alias PpClient.Relay

  @connect_timeout 10_000
  @connect_opts [:binary, packet: :raw, active: false, nodelay: true]
  @attempts 2

  @spec connect({term(), String.t(), :inet.port_number()}, pid()) ::
          {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect({_type, host, port}, owner), do: connect(host, port, owner, @attempts)

  defp connect(host, port, _owner, 0) do
    save_connect_failed_host(host, port)
    {:error, :connect_failure}
  end

  defp connect(host, port, owner, attempts_left) do
    case :gen_tcp.connect(connect_address(host), port, @connect_opts, @connect_timeout) do
      {:ok, socket} ->
        Relay.attach(socket, owner)

      {:error, reason} ->
        Logger.debug("Direct connect to #{host}:#{port} failed: #{inspect(reason)}")
        connect(host, port, owner, attempts_left - 1)
    end
  end

  # gen_tcp infers the address family from a parsed address, so an IPv6 literal
  # has to go in as a tuple — as a charlist it would need an explicit `:inet6`
  # and otherwise fails resolution with `:nxdomain`.
  defp connect_address(host) do
    charlist = to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} -> ip
      {:error, :einval} -> charlist
    end
  end

  defp save_connect_failed_host(host, port) do
    failure_key = {host, port}
    current_time = System.system_time(:second)

    # Insert or update failure count atomically
    case :ets.lookup(:connect_failed, failure_key) do
      [{^failure_key, existing_record}] ->
        # Update existing record with incremented count
        updated_record = %{
          existing_record
          | timestamp: current_time,
            count: existing_record.count + 1
        }

        :ets.insert(:connect_failed, {failure_key, updated_record})

      [] ->
        # Insert new failure record
        failure_record = %{
          timestamp: current_time,
          host: host,
          port: port,
          count: 1
        }

        :ets.insert(:connect_failed, {failure_key, failure_record})
    end
  end
end
