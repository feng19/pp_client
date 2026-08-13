defmodule PpClient.BrowserHeaders do
  @moduledoc """
  Browser-shaped HTTP headers for the websocket upgrade request.

  Mint's default upgrade request is a five-line giveaway:

      GET /ws HTTP/1.1
      host: localhost
      user-agent: mint/1.9.3
      upgrade: websocket
      connection: upgrade
      sec-websocket-version: 13
      sec-websocket-key: ...

  `user-agent: mint/1.9.3` names the library outright, and no browser opens a
  websocket with only five headers. This module supplies the headers Chrome
  sends on a `wss://` handshake, so the request body matches the TLS
  fingerprint that `PpClient.TLSProfile` shapes.

  ## What this deliberately does not send

  Chrome sends `Sec-Fetch-*` and `sec-ch-ua*` on navigations and `fetch()`, but
  *not* on a websocket upgrade — adding them here would be an anomaly rather
  than camouflage.

  `Sec-WebSocket-Extensions: permessage-deflate` is also omitted. Chrome always
  sends it, but Wind gives no way to pass `:extensions` through to
  `Mint.WebSocket.upgrade/5`, so advertising it would let the server enable
  compression on frames the client cannot decode.

  ## Ordering and casing

  Header order is a fingerprint of its own, and it is only partly ours to set.
  `Mint.WebSocket.upgrade/5` prepends its own headers and `Mint.HTTP1` prepends
  `Host`, so these headers necessarily follow the websocket ones instead of
  interleaving the way Chrome's do. Casing is recovered by passing
  `case_sensitive_headers: true`, which covers every header except the four
  Mint.WebSocket hardcodes in lowercase.

  ## Usage

  On by default. Per-server, in the endpoint settings map:

      %{uri: "wss://…", type: "exps", headers_profile: :none}       # send nothing
      %{uri: "wss://…", type: "exps", user_agent: "Mozilla/5.0 …"}  # override UA
  """

  # Chrome freezes the minor version parts at 0.0.0. This needs refreshing as
  # Chrome ages — a User-Agent several major versions behind is its own signal.
  @chrome_version "151.0.0.0"
  @chrome_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/#{@chrome_version} Safari/537.36"

  @doc """
  Builds the browser headers for `uri`, in Chrome's relative order.

  Returns `[]` when the setting carries `headers_profile: :none`.
  """
  def headers(%URI{} = uri, setting \\ %{}) do
    case Map.get(setting, :headers_profile, :chrome) do
      :none ->
        []

      :chrome ->
        [
          {"User-Agent", Map.get(setting, :user_agent, @chrome_ua)},
          {"Origin", origin(uri)},
          {"Accept-Encoding", "gzip, deflate, br, zstd"},
          {"Accept-Language", "en-US,en;q=0.9"},
          {"Cache-Control", "no-cache"},
          {"Pragma", "no-cache"}
        ]

      other ->
        raise ArgumentError,
              "unknown :headers_profile #{inspect(other)}, expected :chrome or :none"
    end
  end

  @doc """
  Merges browser headers with the caller's, letting the caller win on any
  header it sets so a duplicate never reaches the wire.
  """
  def merge(browser, custom) do
    taken = MapSet.new(custom, fn {name, _} -> String.downcase(name) end)

    Enum.reject(browser, fn {name, _} -> MapSet.member?(taken, String.downcase(name)) end) ++
      custom
  end

  @doc "The default Chrome User-Agent string."
  def user_agent, do: @chrome_ua

  defp origin(%URI{scheme: scheme, host: host, port: port}) do
    {origin_scheme, default_port} =
      case scheme do
        "wss" -> {"https", 443}
        _ -> {"http", 80}
      end

    if port in [nil, default_port] do
      "#{origin_scheme}://#{host}"
    else
      "#{origin_scheme}://#{host}:#{port}"
    end
  end
end
