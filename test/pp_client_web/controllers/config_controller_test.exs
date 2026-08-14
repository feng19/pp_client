defmodule PpClientWeb.ConfigControllerTest do
  use PpClientWeb.ConnCase

  alias PpClient.Config
  alias PpClient.ProxyServer
  alias PpClient.ServerManager

  @moduletag capture_log: true

  setup do
    on_exit(fn -> ServerManager.delete_server("dl_cf") end)
    :ok
  end

  test "GET /admin/config/export downloads a pp.exs that loads again", %{conn: conn} do
    {:ok, _server} =
      ServerManager.add_server(
        ProxyServer.new(%{
          name: "dl_cf",
          type: "cf-workers",
          opts: %{uri: "wss://dl.example.com", password: "s3cret-password"}
        })
      )

    conn = get(conn, ~p"/admin/config/export")

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(filename="pp.exs")

    body = response(conn, 200)

    # The download is the copy that has to work, so the credentials are in it.
    assert body =~ ~s(password: "s3cret-password")
    assert {:ok, config} = Config.eval_string(body)
    assert {:ok, %{servers: servers}} = Config.build(config)
    assert Enum.any?(servers, &(&1.name == "dl_cf"))
  end
end
