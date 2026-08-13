defmodule PpClient.Test.ClientHello do
  @moduledoc """
  Captures and parses the TLS ClientHello that `:ssl` emits for a given set of
  options, so tests can assert on the wire-level fingerprint rather than on the
  option list we intended to pass.
  """

  @grease [
    0x0A0A,
    0x1A1A,
    0x2A2A,
    0x3A3A,
    0x4A4A,
    0x5A5A,
    0x6A6A,
    0x7A7A,
    0x8A8A,
    0x9A9A,
    0xAAAA,
    0xBABA,
    0xCACA,
    0xDADA,
    0xEAEA,
    0xFAFA
  ]

  @doc """
  Runs `:ssl.connect/4` with `ssl_opts` against a throwaway local listener and
  returns the parsed ClientHello. The handshake never completes — we only need
  the first flight.
  """
  def capture(ssl_opts) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)

    connector =
      spawn(fn ->
        :ssl.connect(~c"127.0.0.1", port, ssl_opts, 2000)
      end)

    try do
      {:ok, sock} = :gen_tcp.accept(lsock, 5000)
      {:ok, <<0x16, _version::16, len::16>>} = :gen_tcp.recv(sock, 5, 5000)
      {:ok, body} = :gen_tcp.recv(sock, len, 5000)
      :gen_tcp.close(sock)
      parse(body)
    after
      Process.exit(connector, :kill)
      :gen_tcp.close(lsock)
    end
  end

  @doc """
  Parses a handshake record body into its ClientHello parts.
  """
  def parse(<<0x01, len::24, hello::binary-size(len)>>) do
    <<legacy_version::16, _random::binary-size(32), sid_len, _sid::binary-size(sid_len),
      cs_len::16, ciphers::binary-size(cs_len), comp_len, _comp::binary-size(comp_len),
      ext_len::16, exts::binary-size(ext_len)>> = hello

    %{
      legacy_version: legacy_version,
      session_id_len: sid_len,
      ciphers: for(<<c::16 <- ciphers>>, do: c),
      extensions: parse_extensions(exts, [])
    }
  end

  defp parse_extensions(<<>>, acc), do: Enum.reverse(acc)

  defp parse_extensions(<<type::16, len::16, data::binary-size(len), rest::binary>>, acc),
    do: parse_extensions(rest, [{type, data} | acc])

  @doc "Extension types in wire order."
  def extension_types(info), do: Enum.map(info.extensions, &elem(&1, 0))

  @doc "Raw payload of extension `type`, or `nil`."
  def extension(info, type) do
    case List.keyfind(info.extensions, type, 0) do
      {^type, data} -> data
      nil -> nil
    end
  end

  @doc "supported_groups (extension 10) as integers, in wire order."
  def groups(info), do: u16_list(extension(info, 10))

  @doc "signature_algorithms (extension 13) as integers, in wire order."
  def signature_algs(info), do: u16_list(extension(info, 13))

  defp u16_list(nil), do: []
  defp u16_list(<<_len::16, rest::binary>>), do: for(<<v::16 <- rest>>, do: v)

  @doc "ALPN protocol list (extension 16)."
  def alpn(info) do
    case extension(info, 16) do
      nil -> []
      <<_list_len::16, rest::binary>> -> alpn_protocols(rest, [])
    end
  end

  defp alpn_protocols(<<>>, acc), do: Enum.reverse(acc)

  defp alpn_protocols(<<len, proto::binary-size(len), rest::binary>>, acc),
    do: alpn_protocols(rest, [proto | acc])

  @doc """
  The JA4_a fingerprint prefix, e.g. `"t13d1607h1"` — transport, TLS version,
  SNI presence, cipher count, extension count and first ALPN value.
  """
  def ja4_a(info) do
    ciphers = Enum.reject(info.ciphers, &(&1 in @grease))
    exts = info |> extension_types() |> Enum.reject(&(&1 in @grease))

    version =
      case extension(info, 43) do
        <<_len, rest::binary>> ->
          for(<<v::16 <- rest>>, do: v)
          |> Enum.reject(&(&1 in @grease))
          |> Enum.max(fn -> info.legacy_version end)

        nil ->
          info.legacy_version
      end

    version_tag =
      case version do
        0x0304 -> "13"
        0x0303 -> "12"
        _ -> "00"
      end

    sni = if extension(info, 0), do: "d", else: "i"

    alpn_tag =
      case alpn(info) do
        [] -> "00"
        [first | _] -> String.first(first) <> String.last(first)
      end

    "t" <>
      version_tag <>
      sni <> pad2(length(ciphers)) <> pad2(length(exts)) <> alpn_tag
  end

  defp pad2(n), do: n |> min(99) |> Integer.to_string() |> String.pad_leading(2, "0")
end
