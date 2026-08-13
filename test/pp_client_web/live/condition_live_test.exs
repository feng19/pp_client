defmodule PpClientWeb.ConditionLiveTest do
  use PpClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PpClient.ConditionManager
  alias PpClient.ProfileManager
  alias PpClient.Condition
  alias PpClient.ProxyProfile
  alias PpClient.ProxyServer

  setup do
    # Clean out the test data
    ConditionManager.all_conditions()
    |> Enum.each(fn condition ->
      ConditionManager.delete_condition(condition.id)
    end)

    # Make sure a test profile with valid servers exists
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

      assert html =~ "Conditions"
    end

    test "displays empty state when no conditions exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/conditions")

      assert html =~ "No conditions yet"
    end

    test "searches conditions", %{conn: conn} do
      # Create a test condition
      {:ok, regex} = Condition.pattern_to_regex("*.example.com")

      condition = %Condition{
        condition: regex,
        profile_name: "test-profile",
        enabled: true
      }

      {:ok, _} = ConditionManager.add_condition(condition)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # Search for a condition that exists
      html =
        view
        |> element("form[phx-change='search']")
        |> render_change(%{search: "example"})

      assert html =~ "example"

      # Search for a condition that does not exist
      html =
        view
        |> element("form[phx-change='search']")
        |> render_change(%{search: "nonexistent"})

      refute html =~ "example"
    end

    test "filters by status", %{conn: conn} do
      # Create an enabled condition
      {:ok, regex1} = Condition.pattern_to_regex("*.enabled.com")

      condition1 = %Condition{
        condition: regex1,
        profile_name: "test-profile",
        enabled: true
      }

      {:ok, _} = ConditionManager.add_condition(condition1)

      # Create a disabled condition
      {:ok, regex2} = Condition.pattern_to_regex("*.disabled.com")

      condition2 = %Condition{
        condition: regex2,
        profile_name: "test-profile",
        enabled: false
      }

      {:ok, _} = ConditionManager.add_condition(condition2)

      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # Filter by enabled
      html =
        view
        |> element("form[phx-change='filter_status']")
        |> render_change(%{status: "enabled"})

      assert html =~ "enabled"
      refute html =~ "disabled.com"

      # Filter by disabled
      html =
        view
        |> element("form[phx-change='filter_status']")
        |> render_change(%{status: "disabled"})

      refute html =~ "enabled.com"
      assert html =~ "*.disabled.com"
    end

    test "filters by profile", %{conn: conn} do
      # Create another profile
      profile2 = %ProxyProfile{
        name: "profile2",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile2)

      # Create conditions pointing at different profiles
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

      # Filter by test-profile
      html =
        view
        |> element("form[phx-change='filter_profile']")
        |> render_change(%{profile: "test-profile"})

      assert html =~ "test1"
      refute html =~ "test2"

      # Filter by profile2
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

      # Click the new button to reveal the form
      html = view |> element("button[phx-click='show_new_form']") |> render_click()

      assert html =~ "new-condition-form"
      assert html =~ "new-condition-row"
    end

    test "creates condition", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # Reveal the new condition form
      view |> element("button[phx-click='show_new_form']") |> render_click()

      # Submit the form
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

      # Reveal the new condition form
      view |> element("button[phx-click='show_new_form']") |> render_click()

      # Submitting an empty form should fail
      view
      |> form("#new-condition-form", %{
        pattern: "",
        profile_name: ""
      })
      |> render_submit()

      # No condition was created
      conditions = ConditionManager.all_conditions()
      assert length(conditions) == 0
    end

    test "validates pattern format", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # Reveal the new condition form
      view |> element("button[phx-click='show_new_form']") |> render_click()

      # Submit an invalid pattern
      view
      |> form("#new-condition-form", %{
        pattern: "[invalid regex",
        profile_name: "test-profile"
      })
      |> render_submit()

      # No condition was created
      conditions = ConditionManager.all_conditions()
      assert length(conditions) == 0
    end

    test "creates condition with wildcard pattern", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # Reveal the new condition form
      view |> element("button[phx-click='show_new_form']") |> render_click()

      # Submit a wildcard pattern
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

      # Click the edit button
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

      # Click the edit button
      view
      |> element("button[phx-click='start_edit'][phx-value-id='#{saved.id}']")
      |> render_click()

      # Submit the edit form
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

      # Edit a condition that does not exist by sending the event directly:
      # there is no button to click for it
      html = render_click(view, "start_edit", %{"id" => "999"})

      assert html =~ "No such condition"
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

      assert html =~ "Confirm deletion"
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

      # Open the confirmation dialog
      view
      |> element("button[phx-click='delete_confirm'][phx-value-id='#{saved.id}']")
      |> render_click()

      # Confirm the deletion
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

      # Open the confirmation dialog
      view
      |> element("button[phx-click='delete_confirm'][phx-value-id='#{saved.id}']")
      |> render_click()

      # Cancel the deletion
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
        # The * wildcard renders as "* (matches everything)"
        {"*", "* (matches everything)"},
        {"example.com", "example.com"},
        {"*.*.example.com", "*.*.example.com"}
      ]

      for {pattern, expected_display} <- test_patterns do
        # Create the condition
        {:ok, view, _html} = live(conn, ~p"/admin/conditions")

        # Reveal the new condition form
        view |> element("button[phx-click='show_new_form']") |> render_click()

        # Submit the form
        view
        |> form("#new-condition-form", %{
          pattern: pattern,
          profile_name: "test-profile",
          enabled: "true"
        })
        |> render_submit()

        # Fetch the condition that was just created
        conditions = ConditionManager.all_conditions()
        created = Enum.find(conditions, fn c -> c.profile_name == "test-profile" end)
        assert created != nil

        # Edit it and check the pattern is rendered correctly
        {:ok, view, _html} = live(conn, ~p"/admin/conditions")

        html =
          view
          |> element("button[phx-click='start_edit'][phx-value-id='#{created.id}']")
          |> render_click()

        # The form shows the pattern in the expected display format
        assert html =~ "value=\"#{expected_display}\""

        # Clean up
        ConditionManager.delete_condition(created.id)
      end
    end
  end

  describe "Real-time Updates" do
    test "receives condition updates via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # Create the condition from another process
      {:ok, regex} = Condition.pattern_to_regex("*.pubsub.com")

      condition = %Condition{
        condition: regex,
        profile_name: "test-profile",
        enabled: true
      }

      ConditionManager.add_condition(condition)

      # Broadcast the update
      Phoenix.PubSub.broadcast(PpClient.PubSub, "conditions", {:condition_updated, nil})

      # Give the LiveView time to handle the message
      :timer.sleep(100)

      html = render(view)
      assert html =~ "pubsub"
    end

    test "receives profile updates via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/conditions")

      # Create the profile from another process
      profile = %ProxyProfile{
        name: "new-profile",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile)

      # Broadcast the update
      Phoenix.PubSub.broadcast(PpClient.PubSub, "profiles", {:profile_updated, nil})

      # Give the LiveView time to handle the message
      :timer.sleep(100)

      # Open the new form: the new profile should be listed
      html = view |> element("button[phx-click='show_new_form']") |> render_click()
      assert html =~ "new-profile"
    end
  end
end
