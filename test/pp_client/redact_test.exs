defmodule PpClient.RedactTest do
  use ExUnit.Case, async: true

  alias PpClient.{ProxyServer, Redact}
  alias PpClient.Redact.Secret

  describe "setting/1" do
    test "replaces secrets and keeps the rest of a map" do
      assert Redact.setting(%{uri: "wss://x", password: "s3cret"}) ==
               %{uri: "wss://x", password: :redacted}

      assert Redact.setting(%{uri: "wss://x", encrypt_type: :once, encrypt_key: "k"}) ==
               %{uri: "wss://x", encrypt_type: :once, encrypt_key: :redacted}
    end

    test "keeps a keyword list a keyword list, order included" do
      assert Redact.setting(type: "cf-workers", uri: "wss://x", password: "s3cret") ==
               [type: "cf-workers", uri: "wss://x", password: :redacted]
    end

    test "leaves a setting without secrets alone" do
      setting = %{host: "127.0.0.1", port: 1088}
      assert Redact.setting(setting) == setting
    end
  end

  describe "headers/1" do
    test "blanks credential headers and leaves the others" do
      headers = [
        {"User-Agent", "Mozilla/5.0"},
        {"Authorization", "s3cret"},
        {"Proxy-Authorization", "s3cret"},
        {"X-Proxy-Target", "example.com:443"}
      ]

      assert Redact.headers(headers) == [
               {"User-Agent", "Mozilla/5.0"},
               {"Authorization", "[REDACTED]"},
               {"Proxy-Authorization", "[REDACTED]"},
               {"X-Proxy-Target", "example.com:443"}
             ]
    end

    test "matches the header name whatever its casing" do
      assert Redact.headers([{"authorization", "s3cret"}]) == [{"authorization", "[REDACTED]"}]
    end
  end

  describe "form_params/1 and reveal/1" do
    test "a wrapped secret is still readable but no longer printable" do
      params = Redact.form_params(%{"type" => "cf-workers", "password" => "s3cret"})

      assert Redact.reveal(params["password"]) == "s3cret"
      refute inspect(params) =~ "s3cret"
      # The rest of the field set is left exactly as it was.
      assert params["type"] == "cf-workers"
    end

    test "reveal/1 passes through a value that was never wrapped" do
      assert Redact.reveal("s3cret") == "s3cret"
      assert Redact.reveal(nil) == nil
    end

    test "wrapping is idempotent, so params can go round the form again" do
      once = Redact.form_params(%{"password" => "s3cret"})
      twice = Redact.form_params(once)

      assert Redact.reveal(twice["password"]) == "s3cret"
      refute inspect(twice) =~ "s3cret"
    end

    test "a blank or missing secret is left alone" do
      assert Redact.form_params(%{"password" => ""}) == %{"password" => ""}
      assert Redact.form_params(%{"password" => nil}) == %{"password" => nil}
    end

    test "a secret does not print itself even on its own" do
      assert inspect(Secret.new("s3cret")) == "#PpClient.Redact.Secret<redacted>"
    end
  end

  describe "params/1" do
    test "blanks secrets nested as deep as the form nests them" do
      params = %{
        "name" => "work",
        "servers" => %{
          "0" => %{"type" => "cf-workers", "uri" => "wss://x", "password" => "s3cret"},
          "1" => %{"type" => "exps", "encrypt_key" => "k3y"}
        }
      }

      redacted = Redact.params(params)

      refute inspect(redacted) =~ "s3cret"
      refute inspect(redacted) =~ "k3y"
      assert redacted["servers"]["0"]["uri"] == "wss://x"
      assert redacted["name"] == "work"
    end

    test "leaves a struct value intact instead of walking into it" do
      assert Redact.params(%{"uri" => URI.parse("wss://x")}) == %{"uri" => URI.parse("wss://x")}
    end
  end

  describe "inspecting a server" do
    test "a cf-workers password is not printed" do
      printed = inspect(ProxyServer.cf_workers("wss://pp.example.com", "s3cret"))

      refute printed =~ "s3cret"
      assert printed =~ "password: :redacted"
      # The endpoint is what makes the output worth having.
      assert printed =~ ~s(uri: "wss://pp.example.com")
      assert printed =~ ~s(type: "cf-workers")
    end

    test "an exps encryption key is not printed" do
      printed = inspect(ProxyServer.exps("wss://pp.example.com/ws", :once, "k3y"))

      refute printed =~ "k3y"
      assert printed =~ "encrypt_key: :redacted"
      assert printed =~ "encrypt_type: :once"
    end

    test "survives a nested server, where a stray inspect usually finds one" do
      profile = %{servers: [ProxyServer.cf_workers("wss://pp.example.com", "s3cret")]}

      refute inspect(profile) =~ "s3cret"
    end

    test "a setting given as a keyword list is redacted too" do
      server = %ProxyServer{type: "cf-workers", opts: [uri: "wss://x", password: "s3cret"]}

      refute inspect(server) =~ "s3cret"
    end
  end
end
