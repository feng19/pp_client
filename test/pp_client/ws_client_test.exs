defmodule PpClient.WSClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PpClient.DnsRecord
  alias PpClient.DnsRecordManager
  alias PpClient.WSClient

  @target {0x03, "example.com", 443}
  @password "sup3r-s3cret-cf-workers-password"

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "the credential is out of the client's state once the upgrade is sent" do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)

    setting = Map.merge(setting(port), %{type: "cf-workers", password: @password})
    {:ok, client} = WSClient.start_link(@target, setting, self())

    {:ok, sock} = :gen_tcp.accept(lsock, 5000)
    {:ok, request} = :gen_tcp.recv(sock, 0, 5000)
    # The credential still goes out on the wire; only the copy kept in state goes.
    assert request =~ @password
    :ok = :gen_tcp.send(sock, handshake_reply(request))

    assert_receive {:"$gen_cast", :connected}, 5000

    opts = :sys.get_state(client).opts
    assert Keyword.fetch!(opts, :pp).setting.password == :redacted
    assert {"Authorization", "[REDACTED]"} in Keyword.fetch!(opts, :headers)

    refute inspect(:sys.get_state(client), limit: :infinity, printable_limit: :infinity) =~
             @password

    :gen_tcp.close(sock)
    :gen_tcp.close(lsock)
  end

  defp handshake_reply(request) do
    [_, key] = Regex.run(~r/sec-websocket-key: (\S+)/i, request)

    accept =
      :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
      "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
  end

  test "an upstream that hangs up ends the client normally and tells the owner" do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)

    log =
      capture_log(fn ->
        {:ok, client} = WSClient.start_link(@target, setting(port), self())
        ref = Process.monitor(client)

        {:ok, sock} = :gen_tcp.accept(lsock, 5000)
        {:ok, _upgrade_request} = :gen_tcp.recv(sock, 0, 5000)
        :gen_tcp.close(sock)

        assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 5000
      end)

    :gen_tcp.close(lsock)

    assert_receive {:"$gen_cast", :close}
    refute log =~ "terminating"
  end

  test "a refused connection is reported to the owner and logged, not crashed" do
    # Take a port and hand it straight back so nothing is listening on it.
    {:ok, lsock} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(lsock)
    :gen_tcp.close(lsock)

    log =
      capture_log(fn ->
        {:ok, client} = WSClient.start_link(@target, setting(port), self())
        ref = Process.monitor(client)

        assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 5000
      end)

    assert_receive {:"$gen_cast", :close}
    assert log =~ "econnrefused"
    refute log =~ "terminating"
  end

  # `.invalid` never resolves (RFC 2606), so this only connects if the record is
  # what the dial used.
  test "a DNS record dials its IP while Host and Origin keep the domain" do
    domain = "ws-dns-test.invalid"

    {:ok, _record} =
      DnsRecordManager.add_record(DnsRecord.new(%{domain: domain, ip: "127.0.0.1"}))

    on_exit(fn -> DnsRecordManager.delete_record(domain) end)

    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)

    {:ok, client} =
      WSClient.start_link(@target, %{uri: "ws://#{domain}:#{port}/ws", type: "plain"}, self())

    {:ok, sock} = :gen_tcp.accept(lsock, 5000)
    {:ok, request} = :gen_tcp.recv(sock, 0, 5000)

    assert request =~ "Host: #{domain}:#{port}\r\n"
    assert request =~ "Origin: http://#{domain}:#{port}\r\n"
    refute request =~ "127.0.0.1"

    :ok = :gen_tcp.send(sock, handshake_reply(request))
    assert_receive {:"$gen_cast", :connected}, 5000

    # The dial went to the record's IP, not to the (unresolvable) domain.
    assert Keyword.fetch!(:sys.get_state(client).opts, :uri).host == "127.0.0.1"

    :gen_tcp.close(sock)
    :gen_tcp.close(lsock)
  end

  test "a disabled DNS record is ignored" do
    domain = "ws-dns-disabled.invalid"

    {:ok, _record} =
      DnsRecordManager.add_record(
        DnsRecord.new(%{domain: domain, ip: "127.0.0.1", enable: false})
      )

    on_exit(fn -> DnsRecordManager.delete_record(domain) end)

    log =
      capture_log(fn ->
        {:ok, client} =
          WSClient.start_link(@target, %{uri: "ws://#{domain}:9/ws", type: "plain"}, self())

        ref = Process.monitor(client)
        assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 5000
      end)

    assert log =~ "nxdomain"
  end

  defp setting(port), do: %{uri: "ws://localhost:#{port}/ws", type: "plain"}
end
