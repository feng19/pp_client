defmodule PpClient.ServerManagerTest do
  use ExUnit.Case, async: true

  alias PpClient.ProfileManager
  alias PpClient.ProxyProfile
  alias PpClient.ProxyServer
  alias PpClient.ServerManager

  @moduletag capture_log: true

  # The tables are shared, so every test works on names of its own and cleans up
  # after itself. Profiles go first: a server a profile still refers to cannot be
  # deleted.
  setup context do
    prefix = "sm-#{:erlang.phash2(context.test)}"

    on_exit(fn ->
      ProfileManager.all_profiles()
      |> Enum.filter(&String.starts_with?(&1.name, prefix))
      |> Enum.each(&ProfileManager.delete_profile(&1.name))

      ServerManager.all_servers()
      |> Enum.filter(&String.starts_with?(&1.name, prefix))
      |> Enum.each(&ServerManager.delete_server(&1.name))
    end)

    %{prefix: prefix}
  end

  defp socks5(prefix, suffix \\ "socks") do
    ProxyServer.socks5("#{prefix}-#{suffix}", "127.0.0.1", 1088)
  end

  describe "add_server/1" do
    test "stores the server under its name", %{prefix: prefix} do
      server = socks5(prefix)

      assert {:ok, stored} = ServerManager.add_server(server)
      assert stored.name == server.name
      assert {:ok, ^stored} = ServerManager.get_server(server.name)
      assert ServerManager.exists?(server.name)
    end

    test "derives client_type, which the socks5 routing depends on", %{prefix: prefix} do
      assert {:ok, stored} = ServerManager.add_server(socks5(prefix))
      assert stored.client_type == :socks5

      exps = ProxyServer.exps("#{prefix}-exps", "wss://example.com/ws", :none, nil)
      assert {:ok, stored} = ServerManager.add_server(exps)
      assert stored.client_type == :ws
    end

    test "rejects a duplicate name", %{prefix: prefix} do
      assert {:ok, _} = ServerManager.add_server(socks5(prefix))
      assert {:error, :already_exists} = ServerManager.add_server(socks5(prefix))
    end

    test "rejects an invalid server", %{prefix: prefix} do
      bad_port = %ProxyServer{
        name: "#{prefix}-bad",
        type: "socks5",
        opts: %{host: "127.0.0.1", port: 0}
      }

      assert {:error, _reason} = ServerManager.add_server(bad_port)
      refute ServerManager.exists?("#{prefix}-bad")
    end

    test "rejects a nameless server" do
      nameless = %ProxyServer{name: "", type: "socks5", opts: %{host: "127.0.0.1", port: 1088}}

      assert {:error, "Server name is required"} = ServerManager.add_server(nameless)
    end
  end

  describe "update_server/1" do
    test "replaces the stored server", %{prefix: prefix} do
      {:ok, server} = ServerManager.add_server(socks5(prefix))
      updated = %{server | opts: %{host: "10.0.0.1", port: 9999}}

      assert {:ok, _} = ServerManager.update_server(updated)
      assert {:ok, stored} = ServerManager.get_server(server.name)
      assert stored.opts.port == 9999
    end

    test "reports an unknown server", %{prefix: prefix} do
      assert {:error, :not_found} = ServerManager.update_server(socks5(prefix))
    end
  end

  describe "delete_server/1" do
    test "removes an unreferenced server", %{prefix: prefix} do
      {:ok, server} = ServerManager.add_server(socks5(prefix))

      assert :ok = ServerManager.delete_server(server.name)
      refute ServerManager.exists?(server.name)
    end

    test "refuses while a profile still refers to it", %{prefix: prefix} do
      {:ok, server} = ServerManager.add_server(socks5(prefix))

      {:ok, _} =
        ProfileManager.add_profile(%ProxyProfile{
          name: "#{prefix}-profile",
          type: :remote,
          servers: [server.name]
        })

      assert {:error, {:in_use, ["#{prefix}-profile"]}} ==
               ServerManager.delete_server(server.name)

      assert ServerManager.exists?(server.name)
    end

    test "reports an unknown server" do
      assert {:error, :not_found} = ServerManager.delete_server("no-such-server")
    end
  end

  describe "references/1" do
    test "names the profiles pointing at a server", %{prefix: prefix} do
      {:ok, server} = ServerManager.add_server(socks5(prefix))

      for name <- ["#{prefix}-b", "#{prefix}-a"] do
        {:ok, _} =
          ProfileManager.add_profile(%ProxyProfile{
            name: name,
            type: :remote,
            servers: [server.name]
          })
      end

      assert ServerManager.references(server.name) == ["#{prefix}-a", "#{prefix}-b"]
    end

    test "is empty when nothing refers to it", %{prefix: prefix} do
      {:ok, server} = ServerManager.add_server(socks5(prefix))

      assert ServerManager.references(server.name) == []
    end
  end

  describe "fetch_many/1" do
    test "resolves names to servers", %{prefix: prefix} do
      {:ok, one} = ServerManager.add_server(socks5(prefix, "one"))
      {:ok, two} = ServerManager.add_server(socks5(prefix, "two"))

      assert ServerManager.fetch_many([one.name, two.name]) == [one, two]
    end

    test "skips a name with nothing behind it", %{prefix: prefix} do
      {:ok, server} = ServerManager.add_server(socks5(prefix))

      assert ServerManager.fetch_many(["gone", server.name]) == [server]
    end

    test "keeps disabled servers, so callers can tell them from missing ones", %{prefix: prefix} do
      {:ok, server} = ServerManager.add_server(socks5(prefix))
      {:ok, _} = ServerManager.disable_server(server.name)

      assert [%{enable: false}] = ServerManager.fetch_many([server.name])
    end
  end

  describe "enable_server/1 and disable_server/1" do
    test "flip the flag", %{prefix: prefix} do
      {:ok, server} = ServerManager.add_server(socks5(prefix))

      assert {:ok, %{enable: false}} = ServerManager.disable_server(server.name)

      assert ServerManager.enabled_servers() |> Enum.map(& &1.name) |> Enum.member?(server.name) ==
               false

      assert {:ok, %{enable: true}} = ServerManager.enable_server(server.name)
    end

    test "report an unknown server" do
      assert {:error, :not_found} = ServerManager.enable_server("no-such-server")
      assert {:error, :not_found} = ServerManager.disable_server("no-such-server")
    end
  end
end
