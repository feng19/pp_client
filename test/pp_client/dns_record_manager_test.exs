defmodule PpClient.DnsRecordManagerTest do
  use ExUnit.Case, async: true

  alias PpClient.DnsRecord
  alias PpClient.DnsRecordManager

  @moduletag :capture_log

  # The table is shared, so every test works on a domain of its own.
  defp put_record(domain, ip, opts \\ []) do
    record =
      DnsRecord.new(%{domain: domain, ip: ip, enable: Keyword.get(opts, :enable, true)})

    {:ok, record} = DnsRecordManager.add_record(record)
    on_exit(fn -> DnsRecordManager.delete_record(domain) end)
    record
  end

  describe "DnsRecord.new/1" do
    test "downcases the domain and parses the IP into a tuple" do
      record = DnsRecord.new(%{domain: "  Example.Test ", ip: "203.0.113.10"})

      assert record.domain == "example.test"
      assert record.ip == {203, 0, 113, 10}
      assert record.enable
    end

    test "accepts an IP tuple and an IPv6 literal" do
      assert DnsRecord.new(%{domain: "v4.test", ip: {1, 2, 3, 4}}).ip == {1, 2, 3, 4}

      assert DnsRecord.new(%{domain: "v6.test", ip: "2001:db8::1"}).ip ==
               {8193, 3512, 0, 0, 0, 0, 0, 1}
    end

    test "refuses an IP that does not parse" do
      assert_raise ArgumentError, ~r/invalid IP/, fn ->
        DnsRecord.new(%{domain: "bad-ip.test", ip: "not-an-ip"})
      end
    end

    test "refuses an empty domain" do
      assert_raise ArgumentError, ~r/must have a domain/, fn ->
        DnsRecord.new(%{domain: "", ip: "1.2.3.4"})
      end
    end
  end

  describe "CRUD" do
    test "a record can be added, read back and deleted" do
      domain = "crud.test"
      put_record(domain, "198.51.100.4")

      assert DnsRecordManager.exists?(domain)
      assert {:ok, %DnsRecord{ip: {198, 51, 100, 4}}} = DnsRecordManager.get_record(domain)

      assert :ok = DnsRecordManager.delete_record(domain)
      refute DnsRecordManager.exists?(domain)
      assert {:error, :not_found} = DnsRecordManager.get_record(domain)
    end

    test "a second record for the same domain is refused" do
      domain = "duplicate.test"
      put_record(domain, "198.51.100.5")

      duplicate = DnsRecord.new(%{domain: domain, ip: "198.51.100.6"})
      assert {:error, :already_exists} = DnsRecordManager.add_record(duplicate)
    end

    test "an update replaces the IP" do
      domain = "update.test"
      put_record(domain, "198.51.100.7")

      updated = DnsRecord.new(%{domain: domain, ip: "198.51.100.8"})
      assert {:ok, %DnsRecord{ip: {198, 51, 100, 8}}} = DnsRecordManager.update_record(updated)
      assert {:ok, {198, 51, 100, 8}} = DnsRecordManager.lookup(domain)
    end

    test "updating or deleting an unknown domain reports :not_found" do
      unknown = DnsRecord.new(%{domain: "unknown.test", ip: "198.51.100.9"})

      assert {:error, :not_found} = DnsRecordManager.update_record(unknown)
      assert {:error, :not_found} = DnsRecordManager.delete_record("unknown.test")
    end

    test "a record built by hand is validated on the way in" do
      invalid = %DnsRecord{domain: "handmade.test", ip: "nope"}

      assert {:error, reason} = DnsRecordManager.add_record(invalid)
      assert reason =~ "invalid IP"
      refute DnsRecordManager.exists?("handmade.test")
    end
  end

  describe "lookup/1" do
    test "returns the IP of an enabled record, whatever the case of the query" do
      domain = "lookup.test"
      put_record(domain, "192.0.2.10")

      assert {:ok, {192, 0, 2, 10}} = DnsRecordManager.lookup(domain)
      assert {:ok, {192, 0, 2, 10}} = DnsRecordManager.lookup("LOOKUP.Test")
    end

    test "a disabled record is a miss but stays in the table" do
      domain = "disabled.test"
      put_record(domain, "192.0.2.11", enable: false)

      assert :miss = DnsRecordManager.lookup(domain)
      assert DnsRecordManager.exists?(domain)

      {:ok, _record} = DnsRecordManager.enable_record(domain)
      assert {:ok, {192, 0, 2, 11}} = DnsRecordManager.lookup(domain)

      {:ok, _record} = DnsRecordManager.disable_record(domain)
      assert :miss = DnsRecordManager.lookup(domain)
    end

    test "an unknown domain and an IP literal are both misses" do
      assert :miss = DnsRecordManager.lookup("nothing-here.test")
      assert :miss = DnsRecordManager.lookup("192.0.2.12")
    end
  end

  describe "address/1" do
    test "an IP literal comes back as a tuple so gen_tcp infers the family" do
      assert DnsRecordManager.address("127.0.0.1") == {127, 0, 0, 1}
      assert DnsRecordManager.address("::1") == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "a record hit comes back as a tuple" do
      domain = "address.test"
      put_record(domain, "192.0.2.20")

      assert DnsRecordManager.address(domain) == {192, 0, 2, 20}
    end

    test "anything else stays a charlist for the system resolver" do
      assert DnsRecordManager.address("no-record.test") == ~c"no-record.test"
    end
  end

  describe "records from the config file" do
    @tag :tmp_dir
    test "the dns: section is loaded into the table at boot", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "pp_dns.exs")

      File.write!(path, """
      %{
        dns: [
          %{domain: "Config.Test", ip: "192.0.2.40"},
          %{enable: false, domain: "config-off.test", ip: "192.0.2.41"}
        ]
      }
      """)

      on_exit(fn ->
        DnsRecordManager.delete_record("config.test")
        DnsRecordManager.delete_record("config-off.test")
      end)

      assert %{dns: _records} = PpClient.Application.load_config(path)

      assert {:ok, {192, 0, 2, 40}} = DnsRecordManager.lookup("config.test")
      assert :miss = DnsRecordManager.lookup("config-off.test")
      assert DnsRecordManager.exists?("config-off.test")
    end
  end

  describe "dial/2" do
    test "a hit dials the IP and leaves the domain to Mint's :hostname" do
      domain = "dial.test"
      put_record(domain, "192.0.2.30")

      uri = URI.parse("wss://#{domain}/ws")
      http_opts = [protocols: [:http1], transport_opts: [verify: :verify_none]]

      assert {dial_uri, opts} = DnsRecordManager.dial(uri, http_opts)
      assert dial_uri.host == "192.0.2.30"
      assert dial_uri.path == "/ws"
      assert opts[:hostname] == domain
      # Untouched, and no IPv6 flag for an A record.
      assert opts[:transport_opts] == [verify: :verify_none]
    end

    test "an IPv6 record also switches Mint's IPv6 branch on" do
      domain = "dial-v6.test"
      put_record(domain, "2001:db8::2")

      uri = URI.parse("wss://#{domain}/ws")
      http_opts = [transport_opts: [verify: :verify_none]]

      assert {dial_uri, opts} = DnsRecordManager.dial(uri, http_opts)
      assert dial_uri.host == "2001:db8::2"
      assert opts[:hostname] == domain
      assert opts[:transport_opts][:inet6] == true
      assert opts[:transport_opts][:verify] == :verify_none
    end

    test "a miss leaves the URI and the options alone" do
      uri = URI.parse("wss://no-dial-record.test/ws")
      http_opts = [protocols: [:http1]]

      assert {^uri, ^http_opts} = DnsRecordManager.dial(uri, http_opts)
    end
  end
end
