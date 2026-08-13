defmodule PpClient.TLSProfile do
  @moduledoc """
  Shapes the TLS ClientHello used for outbound `wss://` connections.

  OTP's `:ssl` defaults produce a ClientHello that identifies the runtime as
  Erlang almost immediately: 62 cipher suites, ML-DSA/SLH-DSA/brainpool
  signature algorithms that no browser offers, brainpool curves, and no ALPN
  extension at all. Its JA4 is `t13d620700`, which matches nothing else on the
  internet and is trivial to single out.

  This module replaces the tunable parts of the handshake with the values a
  current Chrome sends, so the connection blends into ordinary browser traffic
  instead of standing out:

    * cipher suites — Chrome's 15, in Chrome's order
    * supported_groups — `x25519mlkem768, x25519, secp256r1, secp384r1`
    * signature_algorithms — Chrome's 8 (setting this also drops OTP's
      `signature_algorithms_cert` extension, which Chrome does not send)
    * ALPN — `http/1.1`, matching a real browser's `wss://` handshake

  ## What this cannot do

  Three parts of the ClientHello are hardcoded in OTP and not reachable through
  any `:ssl` option, so the result is *plausible* rather than *identical* to
  Chrome:

    * `ssl_handshake:cipher_suites/2` always prepends
      `TLS_EMPTY_RENEGOTIATION_INFO_SCSV` (`0x00ff`) on an initial handshake, so
      the list is 16 long where Chrome's is 15. Setting `secure_renegotiate:
      false` is rejected outright by OTP.
    * Extension order comes from `maps:to_list/1` over an internal map, and OTP
      implements only a subset of the extensions Chrome sends — no GREASE, no
      `extended_master_secret`, `session_ticket`, `psk_key_exchange_modes`,
      `compress_certificate`, `application_settings` or `padding`. Seven
      extensions in OTP's fixed order against Chrome's sixteen.
    * OTP emits no GREASE values anywhere.

  The result is JA4 `t13d1607h1` — a coherent modern TLS 1.3 client that no
  longer advertises "Erlang", but still not byte-identical to a browser. Making
  JA3/JA4 actually equal Chrome's requires performing the handshake outside the
  BEAM (a uTLS/BoringSSL helper fronting a local plaintext socket); no
  arrangement of `:ssl` options can get there.

  ## Usage

  Per-server, in the endpoint settings map:

      %{uri: "wss://example.com/ws", type: "exps", tls_profile: :chrome}

  `:chrome` (default for `wss://`) applies the profile above; `:erlang` keeps
  OTP's stock ClientHello. A `:tls_opts` keyword list is merged last and wins
  over everything, for one-off overrides.
  """

  @pt_key {__MODULE__, :chrome_opts}

  # Chrome's cipher suites, in the order Chrome offers them.
  @chrome_ciphers [
    "TLS_AES_128_GCM_SHA256",
    "TLS_AES_256_GCM_SHA384",
    "TLS_CHACHA20_POLY1305_SHA256",
    "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
    "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA",
    "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA",
    "TLS_RSA_WITH_AES_128_GCM_SHA256",
    "TLS_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_RSA_WITH_AES_128_CBC_SHA",
    "TLS_RSA_WITH_AES_256_CBC_SHA"
  ]

  @chrome_groups [:x25519mlkem768, :x25519, :secp256r1, :secp384r1]

  # TLS 1.2 ec_point_formats/elliptic_curves companion to the groups above.
  @chrome_eccs [:secp256r1, :secp384r1]

  @chrome_sigalgs [
    :ecdsa_secp256r1_sha256,
    :rsa_pss_rsae_sha256,
    :rsa_pkcs1_sha256,
    :ecdsa_secp384r1_sha384,
    :rsa_pss_rsae_sha384,
    :rsa_pkcs1_sha384,
    :rsa_pss_rsae_sha512,
    :rsa_pkcs1_sha512
  ]

  @versions [:"tlsv1.3", :"tlsv1.2"]

  # Browsers negotiate websockets over HTTP/1.1 and advertise only that. Wind
  # drives Mint with `protocols: [:http1]` and Mint's HTTP/1 path never checks
  # what ALPN actually selected, so offering "h2" here would let Cloudflare or
  # fly.dev pick h2 and leave us speaking HTTP/1.1 into an h2 connection.
  @alpn ["http/1.1"]

  @doc """
  Builds `:transport_opts` for `Mint.HTTP.connect/4` from a server setting map.

  Returns `[]` for plaintext `ws://`, where TLS options would make `:gen_tcp`
  raise `:badarg`.
  """
  def transport_opts(%URI{scheme: "wss"}, setting), do: transport_opts(setting)
  def transport_opts(%URI{}, _setting), do: []

  @doc """
  Builds `:transport_opts` for a `wss://` connection.
  """
  def transport_opts(setting) when is_map(setting) do
    verify = Map.get(setting, :verify, :verify_none)
    overrides = Map.get(setting, :tls_opts, [])

    setting
    |> Map.get(:tls_profile, :chrome)
    |> base_opts()
    |> Keyword.put(:verify, verify)
    |> Keyword.merge(overrides)
  end

  defp base_opts(:erlang), do: []
  defp base_opts(:chrome), do: chrome_opts()

  defp base_opts(other) do
    raise ArgumentError,
          "unknown :tls_profile #{inspect(other)}, expected :chrome or :erlang"
  end

  @doc """
  The Chrome-shaped `:ssl` options, resolved against this runtime's crypto
  capabilities and cached in `:persistent_term`.

  Values the local OTP/OpenSSL build does not support are dropped rather than
  raising, so a stripped build still connects — with a correspondingly
  different fingerprint.
  """
  def chrome_opts do
    case :persistent_term.get(@pt_key, nil) do
      nil ->
        opts = build_chrome_opts()
        :persistent_term.put(@pt_key, opts)
        opts

      opts ->
        opts
    end
  end

  defp build_chrome_opts do
    [
      versions: @versions,
      ciphers: supported_ciphers(),
      supported_groups: keep_supported(@chrome_groups, :ssl.groups()),
      eccs: keep_supported(@chrome_eccs, :ssl.eccs()),
      signature_algs: keep_supported(@chrome_sigalgs, all_sigalgs()),
      alpn_advertised_protocols: @alpn
    ]
  end

  defp supported_ciphers do
    available =
      @versions
      |> Enum.flat_map(&:ssl.cipher_suites(:all, &1))
      |> MapSet.new()

    ciphers =
      @chrome_ciphers
      |> Enum.map(&:ssl.str_to_suite(String.to_charlist(&1)))
      |> Enum.filter(&(is_map(&1) and MapSet.member?(available, &1)))

    # An empty or near-empty list is worse than useless: :ssl silently ignores
    # it and falls back to its own 62-suite default, quietly restoring the
    # fingerprint this module exists to remove.
    if length(ciphers) < 3 do
      raise "TLS profile resolved only #{length(ciphers)} of #{length(@chrome_ciphers)} " <>
              "cipher suites on this runtime; refusing to fall back to :ssl defaults"
    end

    ciphers
  end

  defp all_sigalgs do
    :ssl.signature_algs(:all, :"tlsv1.3")
  rescue
    _ -> @chrome_sigalgs
  end

  defp keep_supported(wanted, available) do
    Enum.filter(wanted, &(&1 in available))
  end
end
