defmodule PpClient.ConfigTest do
  @moduledoc """
  Writing the runtime tables out as a `pp.exs`, and importing one over them.
  """
  # Every test here writes tables the whole application shares, and `replace/1`
  # empties them, so this module must not overlap with anything.
  use ExUnit.Case, async: false

  alias PpClient.Condition
  alias PpClient.ConditionManager
  alias PpClient.Config
  alias PpClient.DnsRecord
  alias PpClient.DnsRecordManager
  alias PpClient.Endpoint
  alias PpClient.EndpointManager
  alias PpClient.ProfileManager
  alias PpClient.ProxyProfile
  alias PpClient.ProxyServer
  alias PpClient.ServerManager

  @moduletag capture_log: true

  @tables [:endpoints, :servers, :profiles, :conditions, :dns_records]

  setup do
    wipe()
    on_exit(&wipe/0)
    :ok
  end

  describe "dump/1" do
    test "renders the tables as a config the loader accepts again" do
      put_server("rt_exps", %{
        type: "exps",
        opts: %{uri: "wss://rt.example.com/ws", encrypt_type: :once, encrypt_key: "k"}
      })

      put_server("rt_socks", %{
        type: "socks5",
        enable: false,
        opts: %{host: "127.0.0.1", port: 1088}
      })

      put_profile("rt-p", ["rt_exps", "rt_socks"])
      put_condition("*.rt.example.com", "rt-p")
      put_record("RT.Example.com", "192.0.2.10")
      put_endpoint(%{type: :socks5, port: 39_051, enable: false, options: [profile: "rt-p"]})
      Config.put_web(%{server: true, http: [ip: {127, 0, 0, 1}, port: 8081]})

      reload(Config.dump())

      assert {:ok, exps} = ServerManager.get_server("rt_exps")
      assert exps.type == "exps"
      assert exps.client_type == :ws
      assert exps.opts[:uri] == "wss://rt.example.com/ws"
      assert exps.opts[:encrypt_type] == :once
      assert exps.opts[:encrypt_key] == "k"

      assert {:ok, %{enable: false, opts: socks_opts}} = ServerManager.get_server("rt_socks")
      assert socks_opts[:host] == "127.0.0.1"
      assert socks_opts[:port] == 1088

      assert {:ok, profile} = ProfileManager.get_profile("rt-p")
      assert profile.servers == ["rt_exps", "rt_socks"]

      assert [condition] = ConditionManager.all_conditions()
      assert condition.profile_name == "rt-p"
      assert Regex.match?(condition.condition, "a.rt.example.com")

      assert {:ok, {192, 0, 2, 10}} = DnsRecordManager.lookup("rt.example.com")

      assert {:ok, endpoint} = EndpointManager.get_endpoint(39_051)
      assert endpoint.type == :socks5
      assert endpoint.enable == false
      assert endpoint.options == [profile: "rt-p"]

      assert Config.web() == %{server: true, http: [ip: {127, 0, 0, 1}, port: 8081]}
    end

    test "a name that is not a bare atom is quoted, so it survives the round trip" do
      put_server("fly-jp", %{type: "socks5", opts: %{host: "127.0.0.1", port: 1088}})
      put_profile("rt-p", ["fly-jp"])

      dumped = Config.dump()
      assert dumped =~ ~s("fly-jp": %{)
      assert dumped =~ ~s(servers: [:"fly-jp"])

      reload(dumped)

      assert {:ok, _server} = ServerManager.get_server("fly-jp")
      assert {:ok, %{servers: ["fly-jp"]}} = ProfileManager.get_profile("rt-p")
    end

    test "the empty tables render a config that loads" do
      dumped = Config.dump()
      assert dumped =~ "endpoints: []"
      assert dumped =~ ~s(conditions: "")

      reload(dumped)

      assert ServerManager.all_servers() == []
      assert ConditionManager.all_conditions() == []
    end

    test "a disabled condition is written out commented, and the parser skips it" do
      put_condition("*.on.example.com", "direct")
      [off] = put_condition("*.off.example.com", "direct")
      {:ok, _condition} = ConditionManager.disable_condition(off.id)

      dumped = Config.dump()
      assert dumped =~ "*.on.example.com +direct"
      assert dumped =~ "; *.off.example.com +direct"

      reload(dumped)

      assert [remaining] = ConditionManager.all_conditions()
      assert Regex.match?(remaining.condition, "a.on.example.com")
    end

    test "redact: true replaces the credentials with a marker" do
      put_server("rt_cf", %{
        type: "cf-workers",
        opts: %{uri: "wss://rt.example.com", password: "s3cret-password"}
      })

      redacted = Config.dump(redact: true)
      refute redacted =~ "s3cret-password"
      assert redacted =~ "password: :redacted"

      # The download is the copy that has to work, so it is not redacted.
      assert Config.dump() =~ ~s(password: "s3cret-password")
    end
  end

  describe "eval_string/2" do
    test "reads a config file into a map" do
      assert {:ok, %{servers: [rt_socks: _attrs]}} =
               Config.eval_string("""
               %{servers: [rt_socks: %{type: "socks5", opts: [host: "127.0.0.1", port: 1088]}]}
               """)
    end

    test "reports a file that does not end in a map" do
      assert {:error, message} = Config.eval_string("[1, 2, 3]")
      assert message =~ "expected the file to end in a map"
    end

    test "reports a file that will not parse, rather than raising" do
      assert {:error, message} = Config.eval_string("%{servers: [")
      assert is_binary(message)
    end

    test "reports what a config raises while it runs" do
      assert {:error, message} =
               Config.eval_string(~s|%{servers: [], x: System.fetch_env!("PP_NO_SUCH_VAR")}|)

      assert message =~ "PP_NO_SUCH_VAR"
    end
  end

  describe "replace/1" do
    test "swaps every section for what the config says" do
      put_server("gone_socks", %{type: "socks5", opts: %{host: "127.0.0.1", port: 1088}})
      put_profile("gone-p", ["gone_socks"])
      put_condition("*.gone.example.com", "gone-p")
      put_record("gone.example.com", "192.0.2.20")

      {:ok, config} =
        Config.eval_string("""
        %{
          servers: [kept_socks: %{type: "socks5", opts: [host: "127.0.0.1", port: 1089]}],
          profiles: [%{name: "kept-p", type: :remote, servers: [:kept_socks]}],
          conditions: "*.kept.example.com +kept-p",
          dns: [%{domain: "kept.example.com", ip: "192.0.2.21"}]
        }
        """)

      assert {:ok, summary} = Config.replace(config)
      assert summary.servers == 1
      assert summary.conditions == 1
      assert summary.failed_endpoints == []

      assert ServerManager.exists?("kept_socks")
      refute ServerManager.exists?("gone_socks")
      refute ProfileManager.exists?("gone-p")
      assert [%{profile_name: "kept-p"}] = ConditionManager.all_conditions()
      refute DnsRecordManager.exists?("gone.example.com")
      assert DnsRecordManager.exists?("kept.example.com")
    end

    test "keeps the direct profile a config does not mention" do
      {:ok, config} = Config.eval_string("%{profiles: []}")

      assert {:ok, _summary} = Config.replace(config)
      assert {:ok, %{type: :direct}} = ProfileManager.get_profile("direct")
    end

    test "leaves the tables alone when the config does not hold up" do
      put_server("kept_socks", %{type: "socks5", opts: %{host: "127.0.0.1", port: 1088}})

      {:ok, config} =
        Config.eval_string("""
        %{profiles: [%{name: "broken-p", type: :remote, servers: [:no_such_server]}]}
        """)

      assert {:error, message} = Config.replace(config)
      assert message =~ ~s("broken-p")
      assert message =~ ~s("no_such_server")

      # The point of building everything up front: a rejected file changes nothing.
      assert ServerManager.exists?("kept_socks")
      refute ProfileManager.exists?("broken-p")
    end

    test "the next condition added after an import does not land on an imported id" do
      {:ok, config} =
        Config.eval_string(~s|%{conditions: "*.a.example.com +direct\\n*.b.example.com +direct"}|)

      assert {:ok, %{conditions: 2}} = Config.replace(config)

      [added] = put_condition("*.c.example.com", "direct")
      assert added.id == 2
      assert length(ConditionManager.all_conditions()) == 3
    end

    test "binds the listeners the config enables and leaves the disabled ones alone" do
      {:ok, config} =
        Config.eval_string("""
        %{
          endpoints: [
            %{type: :socks5, port: 39_052, options: []},
            %{enable: false, type: :http, port: 39_053, options: []}
          ]
        }
        """)

      assert {:ok, %{endpoints: 2, failed_endpoints: []}} = Config.replace(config)

      assert {:ok, running} = EndpointManager.get_endpoint(39_052)
      assert EndpointManager.running?(running)

      assert {:ok, stopped} = EndpointManager.get_endpoint(39_053)
      refute EndpointManager.running?(stopped)
    end

    test "reports a port it could not bind without failing the import" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      {:ok, config} =
        Config.eval_string("%{endpoints: [%{type: :socks5, port: #{port}, options: []}]}")

      assert {:ok, summary} = Config.replace(config)
      assert [{^port, _reason}] = summary.failed_endpoints
    end
  end

  ## Helpers

  defp reload(source) do
    {:ok, config} = Config.eval_string(source)
    wipe()
    assert :ok = Config.load!(config)
  end

  defp wipe do
    Enum.each(EndpointManager.all_endpoints(), &EndpointManager.stop/1)
    Enum.each(@tables, &:ets.delete_all_objects/1)
    ProfileManager.ensure_direct()
    ConditionManager.resync()
    Config.put_web(nil)
  end

  defp put_server(name, attrs) do
    {:ok, server} = ServerManager.add_server(ProxyServer.new(Map.put(attrs, :name, name)))
    server
  end

  defp put_profile(name, servers) do
    {:ok, profile} = ProfileManager.add_profile(ProxyProfile.remote(name, servers))
    profile
  end

  defp put_condition(pattern, profile_name) do
    {:ok, regex} = Condition.pattern_to_regex(pattern)

    {:ok, condition} =
      ConditionManager.add_condition(%Condition{
        condition: regex,
        profile_name: profile_name,
        enabled: true
      })

    [condition]
  end

  defp put_record(domain, ip) do
    {:ok, record} = DnsRecordManager.add_record(DnsRecord.new(%{domain: domain, ip: ip}))
    record
  end

  defp put_endpoint(attrs) do
    endpoint = Endpoint.new(attrs)
    :ets.insert(:endpoints, {endpoint.port, endpoint})
    endpoint
  end
end
