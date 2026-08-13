defmodule PpClient.TLSProfileTest do
  use ExUnit.Case, async: true

  alias PpClient.Test.ClientHello
  alias PpClient.TLSProfile

  # Chrome's cipher suites. OTP unconditionally prepends
  # TLS_EMPTY_RENEGOTIATION_INFO_SCSV (0x00ff) on an initial handshake, so the
  # wire list is one longer than Chrome's and there is no option to suppress it.
  @scsv 0x00FF
  @chrome_ciphers [
    0x1301,
    0x1302,
    0x1303,
    0xC02B,
    0xC02F,
    0xC02C,
    0xC030,
    0xCCA9,
    0xCCA8,
    0xC013,
    0xC014,
    0x009C,
    0x009D,
    0x002F,
    0x0035
  ]

  @chrome_groups [0x11EC, 0x001D, 0x0017, 0x0018]
  @chrome_sigalgs [0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601]

  defp hello(setting) do
    setting
    |> TLSProfile.transport_opts()
    |> Keyword.merge(
      server_name_indication: ~c"example.com",
      active: false,
      mode: :binary,
      packet: :raw
    )
    |> ClientHello.capture()
  end

  describe "chrome profile" do
    setup do
      %{hello: hello(%{})}
    end

    test "offers Chrome's cipher suites in Chrome's order", %{hello: hello} do
      assert hello.ciphers == [@scsv | @chrome_ciphers]
    end

    test "offers Chrome's supported_groups in order", %{hello: hello} do
      assert ClientHello.groups(hello) == @chrome_groups
    end

    test "offers Chrome's signature algorithms in order", %{hello: hello} do
      assert ClientHello.signature_algs(hello) == @chrome_sigalgs
    end

    test "advertises only http/1.1 over ALPN", %{hello: hello} do
      # Wind drives Mint with protocols: [:http1] and Mint's HTTP/1 path never
      # checks the negotiated protocol, so offering "h2" would let the server
      # select it and leave us speaking HTTP/1.1 into an h2 connection.
      assert ClientHello.alpn(hello) == ["http/1.1"]
    end

    test "drops the signature_algorithms_cert extension Chrome does not send", %{hello: hello} do
      refute 50 in ClientHello.extension_types(hello)
    end

    test "keeps middlebox compatibility mode, like a browser", %{hello: hello} do
      assert hello.session_id_len == 32
    end

    test "produces the expected JA4_a fingerprint", %{hello: hello} do
      assert ClientHello.ja4_a(hello) == "t13d1607h1"
    end

    test "carries none of the Erlang-specific tells", %{hello: hello} do
      # ML-DSA / SLH-DSA / brainpool signature schemes and brainpool curves are
      # the giveaway in OTP's default ClientHello.
      assert Enum.all?(ClientHello.signature_algs(hello), &(&1 < 0x0807))
      refute Enum.any?(ClientHello.groups(hello), &(&1 in 0x001F..0x0021))
    end
  end

  describe "transport_opts/2" do
    test "returns no TLS options for plaintext ws://" do
      # TLS options on a :gen_tcp socket raise :badarg.
      assert TLSProfile.transport_opts(URI.parse("ws://example.com/ws"), %{}) == []
    end

    test "returns the profile for wss://" do
      opts = TLSProfile.transport_opts(URI.parse("wss://example.com/ws"), %{})
      assert opts[:alpn_advertised_protocols] == ["http/1.1"]
    end

    test "preserves the existing verify_none default" do
      assert TLSProfile.transport_opts(%{})[:verify] == :verify_none
    end

    test "honours an explicit :verify setting" do
      assert TLSProfile.transport_opts(%{verify: :verify_peer})[:verify] == :verify_peer
    end

    test ":tls_opts overrides the profile" do
      opts = TLSProfile.transport_opts(%{tls_opts: [alpn_advertised_protocols: ["h2"]]})
      assert opts[:alpn_advertised_protocols] == ["h2"]
    end

    test "rejects an unknown profile name" do
      assert_raise ArgumentError, ~r/unknown :tls_profile/, fn ->
        TLSProfile.transport_opts(%{tls_profile: :firefox})
      end
    end
  end

  describe "erlang escape hatch" do
    test "restores OTP's stock ClientHello" do
      hello = hello(%{tls_profile: :erlang})

      assert length(hello.ciphers) > 20
      assert ClientHello.alpn(hello) == []
    end
  end
end
