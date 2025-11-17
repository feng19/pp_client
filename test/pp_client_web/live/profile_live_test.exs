defmodule PpClientWeb.ProfileLiveTest do
  use PpClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PpClient.ProfileManager
  alias PpClient.ProxyProfile
  alias PpClient.ProxyServer

  @moduletag capture_log: true

  setup do
    # 清理测试数据
    ProfileManager.all_profiles()
    |> Enum.each(fn profile ->
      unless profile.name == "direct" do
        ProfileManager.delete_profile(profile.name)
      end
    end)

    :ok
  end

  describe "Index" do
    test "lists all profiles", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/profiles")

      assert html =~ "Profile 管理"
      assert html =~ "direct"
    end

    test "searches profiles", %{conn: conn} do
      # 创建测试 profile（使用有效的 servers）
      profile = %ProxyProfile{
        name: "test-profile",
        type: :remote,
        enabled: true,
        servers: [ProxyServer.socks5("127.0.0.1", 1080)]
      }

      ProfileManager.add_profile(profile)

      {:ok, view, _html} = live(conn, ~p"/admin/profiles")

      # 搜索存在的 profile
      html =
        view
        |> element("form")
        |> render_change(%{search: "test"})

      assert html =~ "test-profile"

      # 搜索不存在的 profile
      html =
        view
        |> element("form")
        |> render_change(%{search: "nonexistent"})

      # 检查桌面端表格中不包含 test-profile
      refute html =~ ~r/<tbody id="profiles"[^>]*>.*test-profile.*<\/tbody>/s
    end

    test "displays empty state when no profiles match search", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles")

      html =
        view
        |> element("form")
        |> render_change(%{search: "nonexistent-profile"})

      assert html =~ "没有找到匹配的 Profile"
    end
  end

  describe "New" do
    test "displays new profile form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/profiles/new")

      assert html =~ "新建 Profile"
      assert html =~ "名称"
      assert html =~ "类型"
    end

    test "creates direct profile", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # 先删除默认的服务器（direct profile 不需要服务器）
      view
      |> element("button[phx-click='remove_server'][phx-value-index='0']")
      |> render_click()

      assert view
             |> form("#profile-form",
               profile_schema: %{
                 name: "new-direct",
                 type: :direct,
                 enabled: true
               }
             )
             |> render_submit()

      assert_redirect(view, ~p"/admin/profiles")

      {:ok, profile} = ProfileManager.get_profile("new-direct")
      assert profile.name == "new-direct"
      assert profile.type == :direct
      assert profile.enabled == true
    end

    test "creates remote profile with servers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # 先选择类型为 remote（已经有默认服务器）
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "new-remote"})
      |> render_change()

      # 提交表单（使用默认服务器）
      assert view
             |> form("#profile-form",
               profile_schema: %{
                 name: "new-remote",
                 type: :remote,
                 enabled: true,
                 servers: %{
                   "0" => %{
                     type: "socks5",
                     enable: true,
                     host: "127.0.0.1",
                     port: 1080
                   }
                 }
               }
             )
             |> render_submit()

      assert_redirect(view, ~p"/admin/profiles")

      {:ok, profile} = ProfileManager.get_profile("new-remote")
      assert profile.name == "new-remote"
      assert profile.type == :remote
      assert length(profile.servers) == 1
    end

    test "validates required fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      html =
        view
        |> form("#profile-form",
          profile_schema: %{
            name: "",
            type: :direct
          }
        )
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "prevents duplicate profile names", %{conn: conn} do
      # 创建已存在的 profile
      profile = %ProxyProfile{
        name: "existing",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile)

      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      view
      |> form("#profile-form",
        profile_schema: %{
          name: "existing",
          type: :direct,
          enabled: true
        }
      )
      |> render_submit()

      assert has_element?(view, "#profile-form")
    end

    test "validates remote profile must have at least one server", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # 先删除默认的服务器
      view
      |> element("button[phx-click='remove_server'][phx-value-index='0']")
      |> render_click()

      # 尝试提交没有服务器的远程代理 profile
      html =
        view
        |> form("#profile-form",
          profile_schema: %{
            name: "remote-no-servers",
            type: :remote,
            enabled: true
          }
        )
        |> render_submit()

      # 提交后应该显示验证错误在 flash 消息中
      assert html =~ "保存失败"
      assert html =~ "Remote profile must have at least one server"
      # 表单应该仍然存在（没有跳转）
      assert has_element?(view, "#profile-form")
    end

    test "allows creating remote profile with servers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # 选择远程代理类型（已经有默认服务器）
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "remote-with-server"})
      |> render_change()

      # 提交表单应该成功（使用默认服务器）
      assert view
             |> form("#profile-form",
               profile_schema: %{
                 name: "remote-with-server",
                 type: :remote,
                 enabled: true,
                 servers: %{
                   "0" => %{
                     type: "socks5",
                     enable: true,
                     host: "127.0.0.1",
                     port: 1080
                   }
                 }
               }
             )
             |> render_submit()

      assert_redirect(view, ~p"/admin/profiles")

      {:ok, profile} = ProfileManager.get_profile("remote-with-server")
      assert profile.type == :remote
      assert length(profile.servers) == 1
    end
  end

  describe "Edit" do
    test "displays edit profile form", %{conn: conn} do
      profile = %ProxyProfile{
        name: "edit-test",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile)

      {:ok, _view, html} = live(conn, ~p"/admin/profiles/edit-test/edit")

      assert html =~ "编辑 Profile"
      assert html =~ "edit-test"
    end

    test "updates profile", %{conn: conn} do
      profile = %ProxyProfile{
        name: "update-test",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile)

      {:ok, view, _html} = live(conn, ~p"/admin/profiles/update-test/edit")

      assert view
             |> form("#profile-form",
               profile_schema: %{
                 name: "update-test",
                 type: :direct,
                 enabled: false
               }
             )
             |> render_submit()

      assert_redirect(view, ~p"/admin/profiles")

      {:ok, updated} = ProfileManager.get_profile("update-test")
      assert updated.enabled == false
    end

    test "redirects when profile not found", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/profiles"}}} =
               live(conn, ~p"/admin/profiles/nonexistent/edit")
    end
  end

  describe "Toggle Enable" do
    test "enables disabled profile", %{conn: conn} do
      profile = %ProxyProfile{
        name: "toggle-test",
        type: :direct,
        enabled: false,
        servers: []
      }

      ProfileManager.add_profile(profile)

      {:ok, view, _html} = live(conn, ~p"/admin/profiles")

      view
      |> element("#profiles button[phx-click='toggle_enable'][phx-value-name='toggle-test']")
      |> render_click()

      {:ok, updated} = ProfileManager.get_profile("toggle-test")
      assert updated.enabled == true
    end

    test "disables enabled profile", %{conn: conn} do
      profile = %ProxyProfile{
        name: "toggle-test-2",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile)

      {:ok, view, _html} = live(conn, ~p"/admin/profiles")

      view
      |> element("#profiles button[phx-click='toggle_enable'][phx-value-name='toggle-test-2']")
      |> render_click()

      {:ok, updated} = ProfileManager.get_profile("toggle-test-2")
      assert updated.enabled == false
    end
  end

  describe "Delete" do
    test "shows delete confirmation dialog", %{conn: conn} do
      profile = %ProxyProfile{
        name: "delete-test",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile)

      {:ok, view, _html} = live(conn, ~p"/admin/profiles")

      html =
        view
        |> element("#profiles button[phx-click='delete_confirm'][phx-value-name='delete-test']")
        |> render_click()

      assert html =~ "确认删除"
      assert html =~ "delete-test"
    end

    test "deletes profile after confirmation", %{conn: conn} do
      profile = %ProxyProfile{
        name: "delete-test-2",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile)

      {:ok, view, _html} = live(conn, ~p"/admin/profiles")

      # 打开确认对话框 - 使用桌面端按钮
      view
      |> element("#profiles button[phx-click='delete_confirm'][phx-value-name='delete-test-2']")
      |> render_click()

      # 确认删除
      view
      |> element("button[phx-click='delete'][phx-value-name='delete-test-2']")
      |> render_click()

      assert {:error, :not_found} = ProfileManager.get_profile("delete-test-2")
    end

    test "cancels delete", %{conn: conn} do
      profile = %ProxyProfile{
        name: "delete-test-3",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile)

      {:ok, view, _html} = live(conn, ~p"/admin/profiles")

      # 打开确认对话框 - 使用桌面端按钮
      view
      |> element("#profiles button[phx-click='delete_confirm'][phx-value-name='delete-test-3']")
      |> render_click()

      # 取消删除
      view
      |> element("button[phx-click='delete_cancel']")
      |> render_click()

      assert {:ok, _} = ProfileManager.get_profile("delete-test-3")
    end
  end

  describe "Server Management" do
    test "adds server to profile form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # 选择远程代理类型
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "test"})
      |> render_change()

      # 添加服务器
      html =
        view
        |> element("button[phx-click='add_server']")
        |> render_click()

      assert html =~ "服务器 #1"
      assert html =~ "服务器类型"
    end

    test "removes server from profile form", %{conn: conn} do
      profile = %ProxyProfile{
        name: "server-test",
        type: :remote,
        enabled: true,
        servers: [
          ProxyServer.socks5("127.0.0.1", 1080)
        ]
      }

      ProfileManager.add_profile(profile)

      {:ok, view, _html} = live(conn, ~p"/admin/profiles/server-test/edit")

      # 移除服务器
      html =
        view
        |> element("button[phx-click='remove_server'][phx-value-index='0']")
        |> render_click()

      refute html =~ "服务器 1"
    end

    test "displays SOCKS5 specific fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # 选择远程代理类型并添加服务器
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "test"})
      |> render_change()

      view
      |> element("button[phx-click='add_server']")
      |> render_click()

      # 默认是 SOCKS5 类型，应该显示主机和端口字段
      html = render(view)
      assert html =~ "主机地址"
      assert html =~ "端口"
      refute html =~ "WebSocket URI"
      refute html =~ "密码"
      refute html =~ "加密类型"
    end

    test "displays EXPS specific fields when server type changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # 选择远程代理类型
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "test"})
      |> render_change()

      # 更改默认服务器类型为 EXPS
      html =
        view
        |> form("#profile-form",
          profile_schema: %{
            type: :remote,
            name: "test",
            servers: %{
              "0" => %{type: "exps"}
            }
          }
        )
        |> render_change()

      # 应该显示 EXPS 特定字段
      assert html =~ "WebSocket URI"
      assert html =~ "加密类型"
      assert html =~ "加密密钥"
      # 注意：由于可能有多个服务器，我们只检查 EXPS 字段存在
    end

    test "displays CF Workers specific fields when server type changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # 选择远程代理类型
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "test"})
      |> render_change()

      # 更改默认服务器类型为 CF Workers
      html =
        view
        |> form("#profile-form",
          profile_schema: %{
            type: :remote,
            name: "test",
            servers: %{
              "0" => %{type: "cf-workers"}
            }
          }
        )
        |> render_change()

      # 应该显示 CF Workers 特定字段
      assert html =~ "WebSocket URI"
      assert html =~ "密码"
      # 注意：由于可能有多个服务器，我们只检查 CF Workers 字段存在
    end

    test "edits profile with EXPS server shows correct fields", %{conn: conn} do
      profile = %ProxyProfile{
        name: "exps-test",
        type: :remote,
        enabled: true,
        servers: [
          ProxyServer.exps("wss://example.com/ws", :none, nil)
        ]
      }

      ProfileManager.add_profile(profile)

      {:ok, _view, html} = live(conn, ~p"/admin/profiles/exps-test/edit")

      # 应该显示 EXPS 特定字段
      assert html =~ "WebSocket URI"
      assert html =~ "加密类型"
      assert html =~ "wss://example.com/ws"
    end

    test "edits profile with CF Workers server shows correct fields", %{conn: conn} do
      profile = %ProxyProfile{
        name: "cf-test",
        type: :remote,
        enabled: true,
        servers: [
          ProxyServer.cf_workers("wss://worker.example.com", "secret123")
        ]
      }

      ProfileManager.add_profile(profile)

      {:ok, _view, html} = live(conn, ~p"/admin/profiles/cf-test/edit")

      # 应该显示 CF Workers 特定字段
      assert html =~ "WebSocket URI"
      assert html =~ "密码"
      assert html =~ "wss://worker.example.com"
    end

    test "edits profile with SOCKS5 server shows correct fields", %{conn: conn} do
      profile = %ProxyProfile{
        name: "socks5-test",
        type: :remote,
        enabled: true,
        servers: [
          ProxyServer.socks5("192.168.1.100", 1088)
        ]
      }

      ProfileManager.add_profile(profile)

      {:ok, _view, html} = live(conn, ~p"/admin/profiles/socks5-test/edit")

      # 应该显示 SOCKS5 特定字段
      assert html =~ "主机地址"
      assert html =~ "端口"
      assert html =~ "192.168.1.100"
      assert html =~ "1088"
    end
  end

  describe "Real-time Updates" do
    test "receives profile updates via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles")

      # 在另一个进程中创建 profile
      profile = %ProxyProfile{
        name: "pubsub-test",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile)

      # 广播更新
      Phoenix.PubSub.broadcast(PpClient.PubSub, "profiles", {:profile_updated, nil})

      # 等待 LiveView 处理消息
      :timer.sleep(100)

      html = render(view)
      assert html =~ "pubsub-test"
    end
  end
end
