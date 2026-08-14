defmodule PpClientWeb.ServerLiveTest do
  use PpClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PpClient.ProfileManager
  alias PpClient.ProxyProfile
  alias PpClient.ProxyServer
  alias PpClient.ServerManager

  @moduletag capture_log: true

  setup do
    # Profiles first: a server a profile still refers to cannot be deleted.
    ProfileManager.all_profiles()
    |> Enum.each(fn profile ->
      unless profile.name == "direct" do
        ProfileManager.delete_profile(profile.name)
      end
    end)

    Enum.each(ServerManager.all_servers(), &ServerManager.delete_server(&1.name))

    :ok
  end

  defp seed_socks5(name \\ "socks-a") do
    {:ok, server} = ServerManager.add_server(ProxyServer.socks5(name, "127.0.0.1", 1088))
    server
  end

  describe "Index" do
    test "lists servers with their endpoint", %{conn: conn} do
      seed_socks5()

      {:ok, _view, html} = live(conn, ~p"/admin/servers")

      assert html =~ "Servers"
      assert html =~ "socks-a"
      assert html =~ "127.0.0.1:1088"
    end

    test "shows the profiles a server is used by", %{conn: conn} do
      server = seed_socks5()

      {:ok, _} =
        ProfileManager.add_profile(%ProxyProfile{
          name: "uses-it",
          type: :remote,
          servers: [server.name]
        })

      {:ok, _view, html} = live(conn, ~p"/admin/servers")

      assert html =~ "uses-it"
    end

    test "searches servers", %{conn: conn} do
      seed_socks5("socks-a")
      seed_socks5("socks-b")

      {:ok, view, _html} = live(conn, ~p"/admin/servers")

      html = view |> element("form[phx-change='search']") |> render_change(%{search: "socks-b"})

      assert html =~ "socks-b"
      refute html =~ "socks-a"
    end

    test "shows an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/servers")

      assert has_element?(view, "#empty-state")
    end
  end

  describe "New" do
    test "creates a socks5 server", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/servers/new")

      assert view
             |> form("#server-form",
               server_schema: %{
                 name: "new-socks",
                 type: "socks5",
                 enable: true,
                 host: "10.0.0.9",
                 port: 1080
               }
             )
             |> render_submit()

      assert_redirect(view, ~p"/admin/servers")

      assert {:ok, server} = ServerManager.get_server("new-socks")
      assert server.type == "socks5"
      assert server.client_type == :socks5
      assert server.opts.port == 1080
    end

    test "rejects a duplicate name", %{conn: conn} do
      seed_socks5("taken")

      {:ok, view, _html} = live(conn, ~p"/admin/servers/new")

      html =
        view
        |> form("#server-form",
          server_schema: %{name: "taken", type: "socks5", host: "127.0.0.1", port: 1088}
        )
        |> render_submit()

      assert html =~ "already exists"
    end

    test "rejects a name that would not survive a trip through pp.exs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/servers/new")

      html =
        view
        |> form("#server-form",
          server_schema: %{name: "not a key", type: "socks5", host: "127.0.0.1", port: 1088}
        )
        |> render_change()

      assert html =~ "may only contain letters, numbers, underscores and dashes"
    end

    test "validates required fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/servers/new")

      html =
        view
        |> form("#server-form", server_schema: %{name: "", type: "socks5"})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end
  end

  describe "type-dependent fields" do
    test "socks5 shows host and port", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/servers/new")

      view
      |> form("#server-form", server_schema: %{type: "socks5"})
      |> render_change()

      assert has_element?(view, "#server_schema_host")
      assert has_element?(view, "#server_schema_port")
      refute has_element?(view, "#server_schema_uri")
    end

    test "exps shows the uri and the encryption fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/servers/new")

      view
      |> form("#server-form", server_schema: %{type: "exps"})
      |> render_change()

      assert has_element?(view, "#server_schema_uri")
      assert has_element?(view, "#server_schema_encrypt_type")
      assert has_element?(view, "#server_schema_encrypt_key")
      refute has_element?(view, "#server_schema_host")
    end

    test "cf-workers shows the uri and the password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/servers/new")

      view
      |> form("#server-form", server_schema: %{type: "cf-workers"})
      |> render_change()

      assert has_element?(view, "#server_schema_uri")
      assert has_element?(view, "#server_schema_password")
      refute has_element?(view, "#server_schema_encrypt_key")
    end

    test "an exps uri must be a websocket url", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/servers/new")

      view |> form("#server-form", server_schema: %{type: "exps"}) |> render_change()

      html =
        view
        |> form("#server-form",
          server_schema: %{name: "bad-uri", type: "exps", uri: "https://example.com"}
        )
        |> render_change()

      assert html =~ "must be a valid WebSocket URL"
    end
  end

  describe "Edit" do
    test "loads the stored server", %{conn: conn} do
      seed_socks5()

      {:ok, _view, html} = live(conn, ~p"/admin/servers/socks-a/edit")

      assert html =~ "Edit server"
      assert html =~ "127.0.0.1"
    end

    test "updates a server in place", %{conn: conn} do
      seed_socks5()

      {:ok, view, _html} = live(conn, ~p"/admin/servers/socks-a/edit")

      view
      |> form("#server-form",
        server_schema: %{name: "socks-a", type: "socks5", host: "10.1.1.1", port: 1099}
      )
      |> render_submit()

      assert {:ok, server} = ServerManager.get_server("socks-a")
      assert server.opts.host == "10.1.1.1"
      assert server.opts.port == 1099
    end

    test "renaming carries every profile reference along", %{conn: conn} do
      server = seed_socks5()

      {:ok, _} =
        ProfileManager.add_profile(%ProxyProfile{
          name: "follows",
          type: :remote,
          servers: [server.name]
        })

      {:ok, view, _html} = live(conn, ~p"/admin/servers/socks-a/edit")

      view
      |> form("#server-form",
        server_schema: %{name: "socks-renamed", type: "socks5", host: "127.0.0.1", port: 1088}
      )
      |> render_submit()

      assert ServerManager.exists?("socks-renamed")
      refute ServerManager.exists?("socks-a")

      assert {:ok, profile} = ProfileManager.get_profile("follows")
      assert profile.servers == ["socks-renamed"]
    end

    test "redirects when the server is gone", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/servers"}}} =
               live(conn, ~p"/admin/servers/no-such/edit")
    end
  end

  describe "Delete" do
    test "removes an unreferenced server", %{conn: conn} do
      seed_socks5()

      {:ok, view, _html} = live(conn, ~p"/admin/servers")

      view |> element("#server-socks-a button[phx-click='delete_confirm']") |> render_click()
      view |> element("button[phx-click='delete'][phx-value-name='socks-a']") |> render_click()

      refute ServerManager.exists?("socks-a")
    end

    test "refuses while a profile still refers to it, and says which", %{conn: conn} do
      server = seed_socks5()

      {:ok, _} =
        ProfileManager.add_profile(%ProxyProfile{
          name: "blocker",
          type: :remote,
          servers: [server.name]
        })

      {:ok, view, _html} = live(conn, ~p"/admin/servers")

      view |> element("#server-socks-a button[phx-click='delete_confirm']") |> render_click()

      html =
        view |> element("button[phx-click='delete'][phx-value-name='socks-a']") |> render_click()

      assert html =~ "Still used by blocker"
      assert ServerManager.exists?("socks-a")
    end
  end

  describe "Toggle Enable" do
    test "disables and re-enables a server", %{conn: conn} do
      seed_socks5()

      {:ok, view, _html} = live(conn, ~p"/admin/servers")

      view |> element("#server-socks-a button[phx-click='toggle_enable']") |> render_click()
      assert {:ok, %{enable: false}} = ServerManager.get_server("socks-a")

      view |> element("#server-socks-a button[phx-click='toggle_enable']") |> render_click()
      assert {:ok, %{enable: true}} = ServerManager.get_server("socks-a")
    end

    test "warns when a profile is left with no enabled server", %{conn: conn} do
      server = seed_socks5()

      {:ok, _} =
        ProfileManager.add_profile(%ProxyProfile{
          name: "stranded",
          type: :remote,
          servers: [server.name]
        })

      {:ok, view, _html} = live(conn, ~p"/admin/servers")

      html =
        view
        |> element("#server-socks-a button[phx-click='toggle_enable']")
        |> render_click()

      assert html =~ "stranded now have no enabled server"
    end
  end

  # Moved here from the profile page along with the credentials themselves: this
  # is now the only form that handles them.
  describe "Credentials in LiveView state" do
    @password "sup3r-s3cret-cf-workers-password"

    setup do
      {:ok, _} =
        ServerManager.add_server(
          ProxyServer.cf_workers("redact-test", "wss://worker.example.com", @password)
        )

      :ok
    end

    test "the edit form still renders the stored password", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/servers/redact-test/edit")

      assert html =~ @password
    end

    test "a crash would not print the stored password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/servers/redact-test/edit")

      refute printed_state(view) =~ @password
    end

    test "a crash would not print a password being typed", %{conn: conn} do
      typed = "just-typed-#{@password}"

      {:ok, view, _html} = live(conn, ~p"/admin/servers/redact-test/edit")

      html =
        view
        |> form("#server-form",
          server_schema: %{
            name: "redact-test",
            type: "cf-workers",
            uri: "wss://worker.example.com",
            password: typed
          }
        )
        |> render_change()

      # The field keeps what was typed into it, and the state still does not say what.
      assert html =~ typed
      refute printed_state(view) =~ typed
    end

    # Everything a crash report would write out: assigns, the form, the changeset.
    defp printed_state(view) do
      view.pid
      |> :sys.get_state()
      |> inspect(limit: :infinity, printable_limit: :infinity)
    end
  end

  describe "Real-time Updates" do
    test "receives server updates via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/servers")

      seed_socks5("pushed-in")
      Phoenix.PubSub.broadcast(PpClient.PubSub, "servers", {:server_updated, nil})

      assert render(view) =~ "pushed-in"
    end
  end
end
