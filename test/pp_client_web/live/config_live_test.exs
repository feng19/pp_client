defmodule PpClientWeb.ConfigLiveTest do
  use PpClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PpClient.ConditionManager
  alias PpClient.Config
  alias PpClient.DnsRecordManager
  alias PpClient.EndpointManager
  alias PpClient.ProfileManager
  alias PpClient.ProxyServer
  alias PpClient.ServerManager

  @moduletag capture_log: true

  @tables [:endpoints, :servers, :profiles, :conditions, :dns_records]

  setup do
    wipe()
    on_exit(&wipe/0)
    :ok
  end

  test "the page previews the running config with the credentials redacted", %{conn: conn} do
    put_server("cfg_cf", %{
      type: "cf-workers",
      opts: %{uri: "wss://cfg.example.com", password: "s3cret-password"}
    })

    {:ok, _view, html} = live(conn, ~p"/admin/config")

    assert html =~ "cfg_cf"
    assert html =~ "wss://cfg.example.com"
    refute html =~ "s3cret-password"
    assert html =~ "redacted"
    assert html =~ ~p"/admin/config/export"
  end

  test "a chosen file is staged with a warning, and staging alone changes nothing", %{conn: conn} do
    put_server("kept_socks", %{type: "socks5", opts: %{host: "127.0.0.1", port: 1088}})

    {:ok, view, _html} = live(conn, ~p"/admin/config")

    html = stage(view, "%{servers: []}")
    assert html =~ "is ready"
    assert html =~ "Replace configuration"

    # Choosing a file only stages it. Pressing that button is the confirmation,
    # and until it is pressed the running configuration is untouched.
    assert ServerManager.exists?("kept_socks")
    assert html =~ "kept_socks"
  end

  test "importing a file replaces the whole configuration", %{conn: conn} do
    put_server("gone_socks", %{type: "socks5", opts: %{host: "127.0.0.1", port: 1088}})

    {:ok, view, _html} = live(conn, ~p"/admin/config")

    html =
      import_source(view, """
      %{
        servers: [kept_socks: %{type: "socks5", opts: [host: "127.0.0.1", port: 1089]}],
        profiles: [%{name: "kept-p", type: :remote, servers: [:kept_socks]}],
        conditions: "*.kept.example.com +kept-p",
        dns: [%{domain: "kept.example.com", ip: "192.0.2.21"}]
      }
      """)

    assert html =~ "Imported 0 endpoints, 1 servers"
    assert html =~ "kept_socks"

    assert ServerManager.exists?("kept_socks")
    refute ServerManager.exists?("gone_socks")
    assert ProfileManager.exists?("kept-p")
    assert [%{profile_name: "kept-p"}] = ConditionManager.all_conditions()
    assert DnsRecordManager.exists?("kept.example.com")
  end

  test "a file that does not hold up is reported on the page and changes nothing", %{conn: conn} do
    put_server("kept_socks", %{type: "socks5", opts: %{host: "127.0.0.1", port: 1088}})

    {:ok, view, _html} = live(conn, ~p"/admin/config")

    html =
      import_source(view, """
      %{profiles: [%{name: "broken-p", type: :remote, servers: [:no_such_server]}]}
      """)

    assert html =~ "nothing changed"
    assert html =~ "no_such_server"

    assert ServerManager.exists?("kept_socks")
    refute ProfileManager.exists?("broken-p")
  end

  test "a file that is not a configuration at all is reported", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config")

    assert import_source(view, "[1, 2, 3]") =~ "expected the file to end in a map"
  end

  test "submitting with no file chosen says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config")

    assert view |> element("#import-form") |> render_submit() =~ "Choose a pp.exs to import first"
  end

  ## Helpers

  defp stage(view, source) do
    file =
      file_input(view, "#import-form", :config, [
        %{name: "pp.exs", content: source, type: "text/plain"}
      ])

    render_upload(file, "pp.exs")
  end

  defp import_source(view, source) do
    stage(view, source)
    view |> element("#import-form") |> render_submit()
  end

  defp put_server(name, attrs) do
    {:ok, server} = ServerManager.add_server(ProxyServer.new(Map.put(attrs, :name, name)))
    server
  end

  defp wipe do
    Enum.each(EndpointManager.all_endpoints(), &EndpointManager.stop/1)
    Enum.each(@tables, &:ets.delete_all_objects/1)
    ProfileManager.ensure_direct()
    ConditionManager.resync()
    Config.put_web(nil)
  end
end
