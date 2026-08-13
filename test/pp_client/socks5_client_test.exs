defmodule PpClient.Socks5ClientTest do
  use ExUnit.Case, async: true

  alias PpClient.Socks5Client

  @moduletag :capture_log

  @ipv4 0x01
  @domain 0x03
  @ipv6 0x04

  # A throwaway SOCKS5 server that completes the greeting, forwards the raw
  # CONNECT request to the test process, then replies success and stays open so
  # the tunnel handed back to the caller is usable.
  defp start_proxy(opts \\ []) do
    test_pid = self()
    reply = Keyword.get(opts, :reply, <<5, 0, 0, @ipv4, 0, 0, 0, 0, 0, 0>>)

    # Written in the same packet as the reply, so a bound-address length the
    # client gets wrong shows up as corrupted tunnel data rather than a timeout.
    trailing = Keyword.get(opts, :trailing, "")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    pid =
      spawn(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener, 5000),
             {:ok, <<5, 1, 0>>} <- :gen_tcp.recv(socket, 3, 5000),
             :ok <- :gen_tcp.send(socket, <<5, 0>>),
             {:ok, request} <- :gen_tcp.recv(socket, 0, 5000) do
          send(test_pid, {:connect_request, request})
          :ok = :gen_tcp.send(socket, reply <> trailing)

          if Keyword.get(opts, :close_after_reply, false) do
            :gen_tcp.close(socket)
          else
            serve(socket, test_pid)
          end
        end
      end)

    %{port: port, pid: pid, setting: %{host: "127.0.0.1", port: port}}
  end

  defp serve(socket, test_pid) do
    receive do
      {:relay, data} ->
        :ok = :gen_tcp.send(socket, data)
        serve(socket, test_pid)

      :expect_upstream ->
        send(test_pid, {:upstream, :gen_tcp.recv(socket, 0, 5000)})
        serve(socket, test_pid)
    after
      5000 -> :ok
    end
  end

  # Returns the CONNECT request the client put on the wire for `target`.
  defp connect_request(target) do
    proxy = start_proxy()
    assert {:ok, _socket} = Socks5Client.connect(target, proxy.setting, self())
    assert_receive {:connect_request, request}, 5000
    request
  end

  describe "connect/3 address encoding" do
    test "domain target is sent as ATYP 3" do
      assert connect_request({@domain, "example.com", 443}) ==
               <<5, 1, 0, @domain, 11, "example.com", 443::16>>
    end

    test "ipv4 target is sent as ATYP 1" do
      assert connect_request({@ipv4, "127.0.0.1", 8080}) ==
               <<5, 1, 0, @ipv4, 127, 0, 0, 1, 8080::16>>
    end

    test "ipv6 target is sent as ATYP 4" do
      assert connect_request({@ipv6, "::1", 8080}) ==
               <<5, 1, 0, @ipv6, 0::size(112), 1::16, 8080::16>>
    end

    test "full form ipv6 target is sent as ATYP 4" do
      assert connect_request({@ipv6, "2001:db8::1", 443}) ==
               <<5, 1, 0, @ipv6, 0x2001::16, 0x0DB8::16, 0::size(80), 1::16, 443::16>>
    end

    # The HTTP entry point tags every host as a domain, IP literals included, so
    # the encoder decides by the address itself rather than by the tag.
    test "ip literal tagged as a domain is still sent as ATYP 1" do
      assert connect_request({@domain, "10.0.0.7", 80}) ==
               <<5, 1, 0, @ipv4, 10, 0, 0, 7, 80::16>>
    end

    test "empty domain is refused without a CONNECT request reaching the proxy" do
      proxy = start_proxy()

      assert {:error, {:invalid_domain, ""}} =
               Socks5Client.connect({@domain, "", 80}, proxy.setting, self())

      refute_receive {:connect_request, _}, 100
    end

    test "non binary address is refused" do
      proxy = start_proxy()
      target = {@ipv4, {127, 0, 0, 1}, 80}

      assert {:error, {:unsupported_target, ^target}} =
               Socks5Client.connect(target, proxy.setting, self())
    end
  end

  describe "connect/3 bound address in the reply" do
    # The bound address is consumed before the tunnel starts; reading the wrong
    # number of bytes leaks reply bytes into the stream or eats payload.
    setup do
      %{target: {@domain, "example.com", 443}}
    end

    test "ipv4 bound address leaves the tunnel aligned", %{target: target} do
      proxy = start_proxy(reply: <<5, 0, 0, @ipv4, 127, 0, 0, 1, 1080::16>>, trailing: "TUNNEL")

      assert {:ok, socket} = Socks5Client.connect(target, proxy.setting, self())
      assert_receive {:tcp, ^socket, "TUNNEL"}, 5000
    end

    test "ipv6 bound address leaves the tunnel aligned", %{target: target} do
      bound = <<0x2001::16, 0x0DB8::16, 0::size(80), 1::16>>
      proxy = start_proxy(reply: <<5, 0, 0, @ipv6, bound::binary, 1080::16>>, trailing: "TUNNEL")

      assert {:ok, socket} = Socks5Client.connect(target, proxy.setting, self())
      assert_receive {:tcp, ^socket, "TUNNEL"}, 5000
    end

    test "domain bound address leaves the tunnel aligned", %{target: target} do
      bound = "proxy.internal"

      proxy =
        start_proxy(
          reply: <<5, 0, 0, @domain, byte_size(bound), bound::binary, 1080::16>>,
          trailing: "TUNNEL"
        )

      assert {:ok, socket} = Socks5Client.connect(target, proxy.setting, self())
      assert_receive {:tcp, ^socket, "TUNNEL"}, 5000
    end

    test "empty domain bound address leaves the tunnel aligned", %{target: target} do
      proxy = start_proxy(reply: <<5, 0, 0, @domain, 0, 1080::16>>, trailing: "TUNNEL")

      assert {:ok, socket} = Socks5Client.connect(target, proxy.setting, self())
      assert_receive {:tcp, ^socket, "TUNNEL"}, 5000
    end

    test "unknown bound address type is refused instead of desyncing", %{target: target} do
      proxy = start_proxy(reply: <<5, 0, 0, 9, 0, 0, 0, 0, 0, 0>>, trailing: "TUNNEL")

      assert {:error, {:unsupported_bound_address_type, 9}} =
               Socks5Client.connect(target, proxy.setting, self())
    end

    test "a truncated reply is reported rather than half consumed", %{target: target} do
      # Claims a 14 byte bound address but sends 4, then goes away.
      proxy = start_proxy(reply: <<5, 0, 0, @domain, 14, "abcd">>, close_after_reply: true)

      assert {:error, {:connect_response_incomplete, :closed}} =
               Socks5Client.connect(target, proxy.setting, self())
    end
  end

  describe "connect/3 tunnel ownership" do
    test "the caller owns the returned socket in both directions" do
      proxy = start_proxy()

      assert {:ok, socket} =
               Socks5Client.connect({@domain, "example.com", 443}, proxy.setting, self())

      assert_receive {:connect_request, _}, 5000
      # Relay.attach/2 announces readiness to the owner before arming the socket.
      assert_receive {:"$gen_cast", :connected}

      # Downstream: armed for active: :once delivery straight to this process.
      send(proxy.pid, {:relay, "downstream"})
      assert_receive {:tcp, ^socket, "downstream"}, 5000

      # Upstream: a plain :gen_tcp.send/2 from the owner.
      send(proxy.pid, :expect_upstream)
      assert :ok = :gen_tcp.send(socket, "upstream")
      assert_receive {:upstream, {:ok, "upstream"}}, 5000
    end
  end
end
