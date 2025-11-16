defmodule PpClientWeb.EndpointLiveTest do
  use PpClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PpClient.EndpointManager

  setup do
    # 清理测试环境
    :ets.delete_all_objects(:endpoints)
    :ok
  end

  describe "Index" do
    test "displays endpoint list page", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/admin/endpoints")

      assert html =~ "Endpoint 管理"
      assert html =~ "管理代理服务端点配置"
    end

    test "displays empty state when no endpoints", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/admin/endpoints")

      assert html =~ "暂无 Endpoint"
    end

    test "displays existing endpoints", %{conn: conn} do
      # 创建测试 endpoint
      endpoint = %PpClient.Endpoint{
        port: 1080,
        type: :socks5,
        ip: {127, 0, 0, 1},
        enable: true
      }

      :ets.insert(:endpoints, {endpoint.port, endpoint})

      {:ok, _index_live, html} = live(conn, ~p"/admin/endpoints")

      assert html =~ "1080"
      assert html =~ "SOCKS5"
      assert html =~ "127.0.0.1"
    end

    test "can search endpoints by port", %{conn: conn} do
      # 创建多个测试 endpoints
      endpoint1 = %PpClient.Endpoint{port: 1080, type: :socks5, ip: {127, 0, 0, 1}, enable: true}
      endpoint2 = %PpClient.Endpoint{port: 8080, type: :http, ip: {127, 0, 0, 1}, enable: true}

      :ets.insert(:endpoints, {endpoint1.port, endpoint1})
      :ets.insert(:endpoints, {endpoint2.port, endpoint2})

      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      # 搜索端口 1080
      html =
        index_live
        |> form("form", %{search: "1080"})
        |> render_change()

      assert html =~ "1080"
      refute html =~ "8080"
    end

    test "can filter endpoints by status", %{conn: conn} do
      # 创建启用和禁用的 endpoints
      enabled = %PpClient.Endpoint{port: 1080, type: :socks5, ip: {127, 0, 0, 1}, enable: true}

      disabled = %PpClient.Endpoint{
        port: 8080,
        type: :http,
        ip: {127, 0, 0, 1},
        enable: false
      }

      :ets.insert(:endpoints, {enabled.port, enabled})
      :ets.insert(:endpoints, {disabled.port, disabled})

      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      # 筛选已启用
      html =
        index_live
        |> element("button", "已启用")
        |> render_click()

      assert html =~ "1080"
      refute html =~ "8080"

      # 筛选已禁用
      html =
        index_live
        |> element("button", "已禁用")
        |> render_click()

      refute html =~ "1080"
      assert html =~ "8080"
    end

    test "opens new endpoint modal", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      {:ok, _new_live, html} =
        index_live
        |> element("a", "新建 Endpoint")
        |> render_click()
        |> follow_redirect(conn, ~p"/admin/endpoints/new")

      assert html =~ "新建 Endpoint"
      assert html =~ "端口"
      assert html =~ "类型"
      assert html =~ "IP 地址"
    end

    test "creates new endpoint with valid data", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints/new")

      assert index_live
             |> form("#endpoint-form",
               endpoint_schema: %{
                 port: "9999",
                 type: "socks5",
                 ip: "127.0.0.1",
                 enable: "true"
               }
             )
             |> render_submit()

      # 验证 endpoint 已创建
      assert {:ok, endpoint} = EndpointManager.get_endpoint(9999)
      assert endpoint.port == 9999
      assert endpoint.type == :socks5
      assert endpoint.ip == {127, 0, 0, 1}
      assert endpoint.enable == true
    end

    test "shows validation errors for invalid data", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints/new")

      html =
        index_live
        |> form("#endpoint-form",
          endpoint_schema: %{
            port: "99999",
            type: "socks5",
            ip: "invalid",
            enable: "true"
          }
        )
        |> render_change()

      assert html =~ "must be less than or equal to 65535"
      assert html =~ "invalid IP address format"
    end

    test "opens edit endpoint modal", %{conn: conn} do
      endpoint = %PpClient.Endpoint{
        port: 1080,
        type: :socks5,
        ip: {127, 0, 0, 1},
        enable: true
      }

      :ets.insert(:endpoints, {endpoint.port, endpoint})

      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      {:ok, _edit_live, html} =
        index_live
        |> element("a[href='/admin/endpoints/1080/edit']")
        |> render_click()
        |> follow_redirect(conn, ~p"/admin/endpoints/1080/edit")

      assert html =~ "编辑 Endpoint"
      assert html =~ "1080"
    end

    test "shows delete confirmation dialog", %{conn: conn} do
      endpoint = %PpClient.Endpoint{
        port: 1080,
        type: :socks5,
        ip: {127, 0, 0, 1},
        enable: true
      }

      :ets.insert(:endpoints, {endpoint.port, endpoint})

      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      html =
        index_live
        |> element("button[phx-click='delete_confirm'][phx-value-port='1080']")
        |> render_click()

      assert html =~ "确认删除"
      assert html =~ "确定要删除端口"
      assert html =~ "1080"
    end

    test "can cancel delete", %{conn: conn} do
      endpoint = %PpClient.Endpoint{
        port: 1080,
        type: :socks5,
        ip: {127, 0, 0, 1},
        enable: true
      }

      :ets.insert(:endpoints, {endpoint.port, endpoint})

      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      # 打开删除对话框
      index_live
      |> element("button[phx-click='delete_confirm'][phx-value-port='1080']")
      |> render_click()

      # 取消删除
      html =
        index_live
        |> element("button[phx-click='delete_cancel']")
        |> render_click()

      # 验证 endpoint 仍然存在
      assert {:ok, _} = EndpointManager.get_endpoint(1080)
      refute html =~ "确认删除"
    end
  end

  describe "Form validation" do
    test "validates port is required", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints/new")

      html =
        index_live
        |> form("#endpoint-form",
          endpoint_schema: %{
            port: "",
            type: "socks5",
            ip: "127.0.0.1"
          }
        )
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "validates port range", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints/new")

      # 测试端口太小
      html =
        index_live
        |> form("#endpoint-form",
          endpoint_schema: %{
            port: "0",
            type: "socks5",
            ip: "127.0.0.1"
          }
        )
        |> render_change()

      assert html =~ "must be greater than 0"

      # 测试端口太大
      html =
        index_live
        |> form("#endpoint-form",
          endpoint_schema: %{
            port: "70000",
            type: "socks5",
            ip: "127.0.0.1"
          }
        )
        |> render_change()

      assert html =~ "must be less than or equal to 65535"
    end

    test "validates IP address format", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints/new")

      html =
        index_live
        |> form("#endpoint-form",
          endpoint_schema: %{
            port: "1080",
            type: "socks5",
            ip: "not.an.ip"
          }
        )
        |> render_change()

      assert html =~ "invalid IP address format"
    end
  end
end
