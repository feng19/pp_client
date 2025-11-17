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
      # 检查桌面端表格中不包含 8080
      assert html =~ ~r/<tbody id="endpoints"[^>]*>.*1080.*<\/tbody>/s
      refute html =~ ~r/<tbody id="endpoints"[^>]*>.*8080.*<\/tbody>/s
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
      # 检查桌面端表格
      assert html =~ ~r/<tbody id="endpoints"[^>]*>.*1080.*<\/tbody>/s
      refute html =~ ~r/<tbody id="endpoints"[^>]*>.*8080.*<\/tbody>/s

      # 筛选已禁用
      html =
        index_live
        |> element("button", "已禁用")
        |> render_click()

      assert html =~ "8080"
      # 检查桌面端表格
      refute html =~ ~r/<tbody id="endpoints"[^>]*>.*1080.*<\/tbody>/s
      assert html =~ ~r/<tbody id="endpoints"[^>]*>.*8080.*<\/tbody>/s
    end

    test "shows new endpoint form when clicking new button", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      html =
        index_live
        |> element("button", "新建 Endpoint")
        |> render_click()

      assert html =~ "new-endpoint-row"
      assert html =~ "未创建"
    end

    test "creates new endpoint with inline form", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      # 点击新建按钮显示表单
      index_live
      |> element("button", "新建 Endpoint")
      |> render_click()

      # 提交新建表单
      index_live
      |> form(
        "#new-endpoint-form",
        %{
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

    test "can cancel new endpoint form", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      # 点击新建按钮显示表单
      html =
        index_live
        |> element("button", "新建 Endpoint")
        |> render_click()

      assert html =~ "new-endpoint-row"

      # 取消新建 - 使用桌面端表单的选择器
      index_live
      |> element("#new-endpoint-form button[phx-click='cancel_new']")
      |> render_click()

      # 验证 show_new_form 状态已更新为 false
      assert :sys.get_state(index_live.pid).socket.assigns.show_new_form == false
    end

    test "starts inline edit mode when clicking edit button", %{conn: conn} do
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
        |> element("#endpoints button[phx-click='start_edit'][phx-value-port='1080']")
        |> render_click()

      # 检查是否进入编辑模式 - 应该有表单元素
      assert html =~ "name=\"new_port\""
      assert html =~ "name=\"type\""
      assert html =~ "name=\"ip\""
    end

    test "can edit endpoint inline", %{conn: conn} do
      endpoint = %PpClient.Endpoint{
        port: 1080,
        type: :socks5,
        ip: {127, 0, 0, 1},
        enable: true
      }

      :ets.insert(:endpoints, {endpoint.port, endpoint})

      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      # 开始编辑 - 使用桌面端按钮
      index_live
      |> element("#endpoints button[phx-click='start_edit'][phx-value-port='1080']")
      |> render_click()

      # 提交编辑
      index_live
      |> form(
        "#edit-form-1080",
        %{
          new_port: "1081",
          type: "http",
          ip: "127.0.0.2",
          enable: "false"
        }
      )
      |> render_submit()

      # 验证更改
      assert {:ok, updated} = EndpointManager.get_endpoint(1081)
      assert updated.port == 1081
      assert updated.type == :http
      assert updated.ip == {127, 0, 0, 2}
      assert updated.enable == false

      # 验证旧端口已删除
      assert {:error, :not_found} = EndpointManager.get_endpoint(1080)
    end

    test "can cancel inline edit", %{conn: conn} do
      endpoint = %PpClient.Endpoint{
        port: 1080,
        type: :socks5,
        ip: {127, 0, 0, 1},
        enable: true
      }

      :ets.insert(:endpoints, {endpoint.port, endpoint})

      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      # 开始编辑 - 使用桌面端按钮
      index_live
      |> element("#endpoints button[phx-click='start_edit'][phx-value-port='1080']")
      |> render_click()

      # 取消编辑 - 使用表单内的按钮
      html =
        index_live
        |> element("#edit-form-1080 button[phx-click='cancel_edit']")
        |> render_click()

      refute html =~ "edit-form-1080"
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
        |> element("#endpoints button[phx-click='delete_confirm'][phx-value-port='1080']")
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

      # 打开删除对话框 - 使用桌面端按钮
      index_live
      |> element("#endpoints button[phx-click='delete_confirm'][phx-value-port='1080']")
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

    test "can delete endpoint", %{conn: conn} do
      endpoint = %PpClient.Endpoint{
        port: 1080,
        type: :socks5,
        ip: {127, 0, 0, 1},
        enable: true
      }

      :ets.insert(:endpoints, {endpoint.port, endpoint})

      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      # 打开删除对话框 - 使用桌面端按钮
      index_live
      |> element("#endpoints button[phx-click='delete_confirm'][phx-value-port='1080']")
      |> render_click()

      # 确认删除
      index_live
      |> element("button[phx-click='delete'][phx-value-port='1080']")
      |> render_click()

      # 验证 endpoint 已删除
      assert {:error, :not_found} = EndpointManager.get_endpoint(1080)
    end
  end
end
