defmodule PpClientWeb.ConditionLiveTest do
  use PpClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PpClient.ConditionManager
  alias PpClient.ProfileManager
  alias PpClient.Condition
  alias PpClient.ProxyProfile
  alias PpClient.ProxyServer

  setup do
    # 清理测试数据
    ConditionManager.all_conditions()
    |> Enum.each(fn condition ->
      ConditionManager.delete_condition(condition.id)
    end)

    # 确保有测试用的 profile（使用有效的 servers）
    unless ProfileManager.exists?("test-profile") do
      profile = %ProxyProfile{
        name: "test-profile",
        type: :remote,
        enabled: true,
        servers: [ProxyServer.socks5("127.0.0.1", 1080)]
      }

      ProfileManager.add_profile(profile)
    end

    :ok
  end

  describe "Index" do
    test "lists all conditions", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/conditions")

      assert html =~ "Condition 管理"
    end

    test "displays empty state when no conditions exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/conditions")

      assert html =~ "暂无 Condition"
    end

    test "searches conditions", %{conn: conn} do
      # 创建测试 condition
      {:ok, regex} = Condition.pattern_to_regex("*.example.com")

      condition = %Condition{
        condition: regex,
        profile_name: "test-profile",
        enabled: true
      }

      {:ok, _} = ConditionManager.add_condition(condition)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 搜索存在的 condition
      html =
        view
        |> element("form[phx-change='search']")
        |> render_change(%{search: "example"})

      assert html =~ "example"

      # 搜索不存在的 condition
      html =
        view
        |> element("form[phx-change='search']")
        |> render_change(%{search: "nonexistent"})

      refute html =~ "example"
    end

    test "filters by status", %{conn: conn} do
      # 创建启用的 condition
      {:ok, regex1} = Condition.pattern_to_regex("*.enabled.com")

      condition1 = %Condition{
        condition: regex1,
        profile_name: "test-profile",
        enabled: true
      }

      {:ok, _} = ConditionManager.add_condition(condition1)

      # 创建禁用的 condition
      {:ok, regex2} = Condition.pattern_to_regex("*.disabled.com")

      condition2 = %Condition{
        condition: regex2,
        profile_name: "test-profile",
        enabled: false
      }

      {:ok, _} = ConditionManager.add_condition(condition2)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 筛选已启用
      html =
        view
        |> element("form[phx-change='filter_status']")
        |> render_change(%{status: "enabled"})

      assert html =~ "enabled"
      refute html =~ "disabled.com"

      # 筛选已禁用
      html =
        view
        |> element("form[phx-change='filter_status']")
        |> render_change(%{status: "disabled"})

      refute html =~ "enabled.com"
      assert html =~ "*.disabled.com"
    end

    test "filters by profile", %{conn: conn} do
      # 创建另一个 profile
      profile2 = %ProxyProfile{
        name: "profile2",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile2)

      # 创建不同 profile 的 conditions
      {:ok, regex1} = Condition.pattern_to_regex("*.test1.com")

      condition1 = %Condition{
        condition: regex1,
        profile_name: "test-profile",
        enabled: true
      }

      {:ok, _} = ConditionManager.add_condition(condition1)

      {:ok, regex2} = Condition.pattern_to_regex("*.test2.com")

      condition2 = %Condition{
        condition: regex2,
        profile_name: "profile2",
        enabled: true
      }

      {:ok, _} = ConditionManager.add_condition(condition2)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 筛选 test-profile
      html =
        view
        |> element("form[phx-change='filter_profile']")
        |> render_change(%{profile: "test-profile"})

      assert html =~ "test1"
      refute html =~ "test2"

      # 筛选 profile2
      html =
        view
        |> element("form[phx-change='filter_profile']")
        |> render_change(%{profile: "profile2"})

      refute html =~ "test1"
      assert html =~ "test2"
    end
  end

  describe "New" do
    test "displays new condition form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 点击新建按钮显示表单
      html = view |> element("button[phx-click='show_new_form']") |> render_click()

      assert html =~ "new-condition-form"
      assert html =~ "new-condition-row"
    end

    test "creates condition", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 显示新建表单
      view |> element("button[phx-click='show_new_form']") |> render_click()

      # 提交表单
      view
      |> form("#new-condition-form", %{
        pattern: "*.example.com",
        profile_name: "test-profile",
        enabled: "true"
      })
      |> render_submit()

      conditions = ConditionManager.all_conditions()
      assert length(conditions) == 1
      assert hd(conditions).profile_name == "test-profile"
    end

    test "validates required fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 显示新建表单
      view |> element("button[phx-click='show_new_form']") |> render_click()

      # 提交空表单应该失败
      view
      |> form("#new-condition-form", %{
        pattern: "",
        profile_name: ""
      })
      |> render_submit()

      # 验证条件没有被创建
      conditions = ConditionManager.all_conditions()
      assert length(conditions) == 0
    end

    test "validates pattern format", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 显示新建表单
      view |> element("button[phx-click='show_new_form']") |> render_click()

      # 提交无效的 pattern
      view
      |> form("#new-condition-form", %{
        pattern: "[invalid regex",
        profile_name: "test-profile"
      })
      |> render_submit()

      # 验证条件没有被创建
      conditions = ConditionManager.all_conditions()
      assert length(conditions) == 0
    end

    test "creates condition with wildcard pattern", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 显示新建表单
      view |> element("button[phx-click='show_new_form']") |> render_click()

      # 提交通配符 pattern
      view
      |> form("#new-condition-form", %{
        pattern: "*",
        profile_name: "test-profile",
        enabled: "true"
      })
      |> render_submit()

      conditions = ConditionManager.all_conditions()
      assert length(conditions) == 1
      assert hd(conditions).condition == :all
    end
  end

  describe "Edit" do
    test "displays edit condition form", %{conn: conn} do
      {:ok, regex} = Condition.pattern_to_regex("*.edit.com")

      condition = %Condition{
        condition: regex,
        profile_name: "test-profile",
        enabled: true
      }

      {:ok, saved} = ConditionManager.add_condition(condition)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 点击编辑按钮
      html =
        view
        |> element("button[phx-click='start_edit'][phx-value-id='#{saved.id}']")
        |> render_click()

      assert html =~ "edit-form-#{saved.id}"
      assert html =~ "edit"
    end

    test "updates condition", %{conn: conn} do
      {:ok, regex} = Condition.pattern_to_regex("*.update.com")

      condition = %Condition{
        condition: regex,
        profile_name: "test-profile",
        enabled: true
      }

      {:ok, saved} = ConditionManager.add_condition(condition)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 点击编辑按钮
      view
      |> element("button[phx-click='start_edit'][phx-value-id='#{saved.id}']")
      |> render_click()

      # 提交编辑表单
      view
      |> form("#edit-form-#{saved.id}", %{
        condition_id: saved.id,
        pattern: "*.updated.com",
        profile_name: "test-profile",
        enabled: "false"
      })
      |> render_submit()

      {:ok, updated} = ConditionManager.get_condition(saved.id)
      assert updated.enabled == false
    end

    test "redirects when condition not found", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 尝试通过事件编辑不存在的 condition（模拟直接调用 handle_event）
      # 由于按钮不存在，我们直接发送事件
      html = render_click(view, "start_edit", %{"id" => "999"})

      assert html =~ "Condition 不存在"
    end
  end

  describe "Toggle Enable" do
    test "enables disabled condition", %{conn: conn} do
      {:ok, regex} = Condition.pattern_to_regex("*.toggle.com")

      condition = %Condition{
        condition: regex,
        profile_name: "test-profile",
        enabled: false
      }

      {:ok, saved} = ConditionManager.add_condition(condition)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      view
      |> element("button[phx-click='toggle_enable'][phx-value-id='#{saved.id}']")
      |> render_click()

      {:ok, updated} = ConditionManager.get_condition(saved.id)
      assert updated.enabled == true
    end

    test "disables enabled condition", %{conn: conn} do
      {:ok, regex} = Condition.pattern_to_regex("*.toggle2.com")

      condition = %Condition{
        condition: regex,
        profile_name: "test-profile",
        enabled: true
      }

      {:ok, saved} = ConditionManager.add_condition(condition)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      view
      |> element("button[phx-click='toggle_enable'][phx-value-id='#{saved.id}']")
      |> render_click()

      {:ok, updated} = ConditionManager.get_condition(saved.id)
      assert updated.enabled == false
    end
  end

  describe "Delete" do
    test "shows delete confirmation dialog", %{conn: conn} do
      {:ok, regex} = Condition.pattern_to_regex("*.delete.com")

      condition = %Condition{
        condition: regex,
        profile_name: "test-profile",
        enabled: true
      }

      {:ok, saved} = ConditionManager.add_condition(condition)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      html =
        view
        |> element("button[phx-click='delete_confirm'][phx-value-id='#{saved.id}']")
        |> render_click()

      assert html =~ "确认删除"
      assert html =~ "#{saved.id}"
    end

    test "deletes condition after confirmation", %{conn: conn} do
      {:ok, regex} = Condition.pattern_to_regex("*.delete2.com")

      condition = %Condition{
        condition: regex,
        profile_name: "test-profile",
        enabled: true
      }

      {:ok, saved} = ConditionManager.add_condition(condition)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 打开确认对话框
      view
      |> element("button[phx-click='delete_confirm'][phx-value-id='#{saved.id}']")
      |> render_click()

      # 确认删除
      view
      |> element("button[phx-click='delete'][phx-value-id='#{saved.id}']")
      |> render_click()

      assert {:error, :not_found} = ConditionManager.get_condition(saved.id)
    end

    test "cancels delete", %{conn: conn} do
      {:ok, regex} = Condition.pattern_to_regex("*.delete3.com")

      condition = %Condition{
        condition: regex,
        profile_name: "test-profile",
        enabled: true
      }

      {:ok, saved} = ConditionManager.add_condition(condition)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 打开确认对话框
      view
      |> element("button[phx-click='delete_confirm'][phx-value-id='#{saved.id}']")
      |> render_click()

      # 取消删除
      view
      |> element("button[phx-click='delete_cancel']")
      |> render_click()

      assert {:ok, _} = ConditionManager.get_condition(saved.id)
    end
  end

  describe "Pattern Conversion" do
    test "converts pattern to regex and back correctly", %{conn: conn} do
      test_patterns = [
        {"*.example.com", "*.example.com"},
        {"api.*.com", "api.*.com"},
        {"?.example.com", "?.example.com"},
        # 通配符 * 会被显示为 "* (匹配所有)"
        {"*", "* (匹配所有)"},
        {"example.com", "example.com"},
        {"*.*.example.com", "*.*.example.com"}
      ]

      for {pattern, expected_display} <- test_patterns do
        # 创建 condition
        {:ok, view, _html} = live(conn, ~p"/admin/conditions")

        # 显示新建表单
        view |> element("button[phx-click='show_new_form']") |> render_click()

        # 提交表单
        view
        |> form("#new-condition-form", %{
          pattern: pattern,
          profile_name: "test-profile",
          enabled: "true"
        })
        |> render_submit()

        # 获取刚创建的 condition
        conditions = ConditionManager.all_conditions()
        created = Enum.find(conditions, fn c -> c.profile_name == "test-profile" end)
        assert created != nil

        # 编辑并验证 pattern 显示正确
        {:ok, view, _html} = live(conn, ~p"/admin/conditions")

        html =
          view
          |> element("button[phx-click='start_edit'][phx-value-id='#{created.id}']")
          |> render_click()

        # 验证表单中显示的 pattern（使用期望的显示格式）
        assert html =~ "value=\"#{expected_display}\""

        # 清理
        ConditionManager.delete_condition(created.id)
      end
    end
  end

  describe "Real-time Updates" do
    test "receives condition updates via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 在另一个进程中创建 condition
      {:ok, regex} = Condition.pattern_to_regex("*.pubsub.com")

      condition = %Condition{
        condition: regex,
        profile_name: "test-profile",
        enabled: true
      }

      ConditionManager.add_condition(condition)

      # 广播更新
      Phoenix.PubSub.broadcast(PpClient.PubSub, "conditions", {:condition_updated, nil})

      # 等待 LiveView 处理消息
      :timer.sleep(100)

      html = render(view)
      assert html =~ "pubsub"
    end

    test "receives profile updates via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # 在另一个进程中创建 profile
      profile = %ProxyProfile{
        name: "new-profile",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile)

      # 广播更新
      Phoenix.PubSub.broadcast(PpClient.PubSub, "profiles", {:profile_updated, nil})

      # 等待 LiveView 处理消息
      :timer.sleep(100)

      # 打开新建表单，应该能看到新的 profile
      html = view |> element("button[phx-click='show_new_form']") |> render_click()
      assert html =~ "new-profile"
    end
  end
end
