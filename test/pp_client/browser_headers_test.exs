defmodule PpClient.BrowserHeadersTest do
  use ExUnit.Case, async: true

  alias PpClient.BrowserHeaders
  alias PpClient.Test.UpgradeRequest

  describe "headers/2" do
    test "sends Chrome's websocket-handshake headers" do
      names =
        URI.parse("wss://example.com/ws")
        |> BrowserHeaders.headers()
        |> Enum.map(&elem(&1, 0))

      assert names == [
               "User-Agent",
               "Origin",
               "Accept-Encoding",
               "Accept-Language",
               "Cache-Control",
               "Pragma"
             ]
    end

    test "omits headers Chrome does not send on a websocket upgrade" do
      names =
        URI.parse("wss://example.com/ws")
        |> BrowserHeaders.headers()
        |> Enum.map(&(&1 |> elem(0) |> String.downcase()))

      # Sec-Fetch-* and sec-ch-ua* belong to navigations and fetch(), not to a
      # websocket handshake; sending them would be an anomaly, not camouflage.
      refute Enum.any?(names, &String.starts_with?(&1, "sec-fetch"))
      refute Enum.any?(names, &String.starts_with?(&1, "sec-ch-ua"))
    end

    test "derives Origin from the websocket URI" do
      assert origin("wss://example.com/ws") == "https://example.com"
      assert origin("ws://example.com/ws") == "http://example.com"
      assert origin("wss://example.com:8443/ws") == "https://example.com:8443"
      assert origin("ws://example.com:8080/ws") == "http://example.com:8080"
    end

    test "omits the default port from Origin, as a browser does" do
      assert origin("wss://example.com:443/ws") == "https://example.com"
      assert origin("ws://example.com:80/ws") == "http://example.com"
    end

    test "honours a custom User-Agent" do
      headers =
        BrowserHeaders.headers(URI.parse("wss://example.com/ws"), %{user_agent: "custom/1.0"})

      assert {"User-Agent", "custom/1.0"} in headers
    end

    test "sends nothing when disabled" do
      assert BrowserHeaders.headers(URI.parse("wss://example.com/ws"), %{headers_profile: :none}) ==
               []
    end

    test "rejects an unknown profile name" do
      assert_raise ArgumentError, ~r/unknown :headers_profile/, fn ->
        BrowserHeaders.headers(URI.parse("wss://example.com/ws"), %{headers_profile: :safari})
      end
    end

    defp origin(uri) do
      URI.parse(uri) |> BrowserHeaders.headers() |> List.keyfind("Origin", 0) |> elem(1)
    end
  end

  describe "merge/2" do
    test "keeps caller headers and appends them after the browser ones" do
      merged = BrowserHeaders.merge([{"User-Agent", "chrome"}], [{"Authorization", "token"}])
      assert merged == [{"User-Agent", "chrome"}, {"Authorization", "token"}]
    end

    test "lets the caller override a browser header without duplicating it" do
      merged = BrowserHeaders.merge([{"User-Agent", "chrome"}], [{"user-agent", "mine"}])
      assert merged == [{"user-agent", "mine"}]
    end
  end

  describe "the request on the wire" do
    test "no longer advertises Mint" do
      request = UpgradeRequest.capture()
      refute UpgradeRequest.get(request, "user-agent") =~ "mint"
      assert UpgradeRequest.get(request, "user-agent") =~ "Chrome/"
    end

    test "carries the browser headers" do
      request = UpgradeRequest.capture()

      assert UpgradeRequest.get(request, "accept-encoding") == "gzip, deflate, br, zstd"
      assert UpgradeRequest.get(request, "accept-language") == "en-US,en;q=0.9"
      assert UpgradeRequest.get(request, "cache-control") == "no-cache"
      assert UpgradeRequest.get(request, "pragma") == "no-cache"
      assert UpgradeRequest.get(request, "origin") =~ "http://localhost:"
    end

    test "preserves browser casing on the headers we control" do
      # Mint lowercases everything unless case_sensitive_headers is set; the
      # four websocket headers stay lowercase because Mint.WebSocket hardcodes
      # them, which no option reaches.
      names = UpgradeRequest.capture() |> UpgradeRequest.names()

      assert "Host" in names
      assert "User-Agent" in names
      assert "Origin" in names
      assert "Accept-Encoding" in names
    end

    test "sends no duplicate header names" do
      names = UpgradeRequest.capture() |> UpgradeRequest.names() |> Enum.map(&String.downcase/1)
      assert names == Enum.uniq(names)
    end

    test "keeps the cf-workers headers alongside the browser ones" do
      request =
        UpgradeRequest.capture(%{type: "cf-workers", password: "secret"})

      assert UpgradeRequest.get(request, "authorization") == "secret"
      assert UpgradeRequest.get(request, "x-proxy-target") == "example.com:443"
      assert UpgradeRequest.get(request, "user-agent") =~ "Chrome/"
    end

    test "still sends the websocket handshake headers" do
      request = UpgradeRequest.capture()

      assert UpgradeRequest.get(request, "upgrade") == "websocket"
      assert UpgradeRequest.get(request, "connection") == "upgrade"
      assert UpgradeRequest.get(request, "sec-websocket-version") == "13"
      assert UpgradeRequest.get(request, "sec-websocket-key") != nil
    end

    test "sends only the websocket headers when disabled" do
      request = UpgradeRequest.capture(%{headers_profile: :none})
      refute UpgradeRequest.get(request, "origin")
      assert UpgradeRequest.get(request, "user-agent") =~ "mint"
    end
  end
end
