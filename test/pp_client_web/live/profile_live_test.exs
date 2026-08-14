defmodule PpClientWeb.ProfileLiveTest do
  use PpClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PpClient.ProfileManager
  alias PpClient.ProxyProfile
  alias PpClient.ProxyServer
  alias PpClient.ServerManager

  @moduletag capture_log: true

  @server_name "socks5-local"

  setup do
    # Profiles first: a server a profile still refers to cannot be deleted.
    ProfileManager.all_profiles()
    |> Enum.each(fn profile ->
      unless profile.name == "direct" do
        ProfileManager.delete_profile(profile.name)
      end
    end)

    Enum.each(ServerManager.all_servers(), &ServerManager.delete_server(&1.name))

    # The picker only offers servers that exist, and LiveViewTest refuses to
    # submit a select value that is not among the rendered options.
    {:ok, server} = ServerManager.add_server(ProxyServer.socks5(@server_name, "127.0.0.1", 1080))

    %{server: server}
  end

  describe "Index" do
    test "lists all profiles", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/profiles")

      assert html =~ "Profiles"
      assert html =~ "direct"
    end

    test "searches profiles", %{conn: conn} do
      # Create a test profile with valid servers
      profile = %ProxyProfile{
        name: "test-profile",
        type: :remote,
        enabled: true,
        servers: [@server_name]
      }

      ProfileManager.add_profile(profile)

      {:ok, view, _html} = live(conn, ~p"/admin/profiles")

      # Search for a profile that exists
      html =
        view
        |> element("form")
        |> render_change(%{search: "test"})

      assert html =~ "test-profile"

      # Search for a profile that does not exist
      html =
        view
        |> element("form")
        |> render_change(%{search: "nonexistent"})

      # The desktop table must not contain test-profile
      refute html =~ ~r/<tbody id="profiles"[^>]*>.*test-profile.*<\/tbody>/s
    end

    test "displays empty state when no profiles match search", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles")

      html =
        view
        |> element("form")
        |> render_change(%{search: "nonexistent-profile"})

      assert html =~ "No matching profile"
    end
  end

  describe "New" do
    test "displays new profile form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/profiles/new")

      assert html =~ "New Profile"
      assert html =~ "Name"
      assert html =~ "Type"
    end

    test "creates direct profile", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

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

      assert view
             |> form("#profile-form",
               profile_schema: %{
                 name: "new-remote",
                 type: :remote,
                 enabled: true,
                 servers: [@server_name]
               }
             )
             |> render_submit()

      assert_redirect(view, ~p"/admin/profiles")

      {:ok, profile} = ProfileManager.get_profile("new-remote")
      assert profile.name == "new-remote"
      assert profile.type == :remote
      assert profile.servers == [@server_name]
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
      # Create a profile that already exists
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

      # Submitting with nothing selected: the form always posts a blank
      # servers[] entry, so the empty list really reaches the changeset.
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

      assert html =~ "remote proxy profile must have at least one server"
      refute ProfileManager.exists?("remote-no-servers")
      # The form is still there, no redirect happened
      assert has_element?(view, "#profile-form")
    end

    test "allows creating remote profile with servers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "remote-with-server"})
      |> render_change()

      assert view
             |> form("#profile-form",
               profile_schema: %{
                 name: "remote-with-server",
                 type: :remote,
                 enabled: true,
                 servers: [@server_name]
               }
             )
             |> render_submit()

      assert_redirect(view, ~p"/admin/profiles")

      {:ok, profile} = ProfileManager.get_profile("remote-with-server")
      assert profile.type == :remote
      assert profile.servers == [@server_name]
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

      assert html =~ "Edit Profile"
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

      assert html =~ "Confirm deletion"
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

      # Open the confirmation dialog with the desktop button
      view
      |> element("#profiles button[phx-click='delete_confirm'][phx-value-name='delete-test-2']")
      |> render_click()

      # Confirm the deletion
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

      # Open the confirmation dialog with the desktop button
      view
      |> element("#profiles button[phx-click='delete_confirm'][phx-value-name='delete-test-3']")
      |> render_click()

      # Cancel the deletion
      view
      |> element("button[phx-click='delete_cancel']")
      |> render_click()

      assert {:ok, _} = ProfileManager.get_profile("delete-test-3")
    end
  end

  describe "Server picker" do
    test "offers the defined servers by name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      assert has_element?(view, "#profile_schema_servers option[value='#{@server_name}']")
    end

    test "marks a disabled server so it is not picked by mistake", %{conn: conn} do
      {:ok, _} = ServerManager.disable_server(@server_name)

      {:ok, _view, html} = live(conn, ~p"/admin/profiles/new")

      assert html =~ "#{@server_name} (disabled)"
    end

    test "points at the Servers page when there is nothing to pick", %{conn: conn} do
      :ok = ServerManager.delete_server(@server_name)

      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      refute has_element?(view, "#profile_schema_servers")
      # Scoped to the modal: the navbar links there from every page.
      assert has_element?(view, ".modal a[href='/admin/servers']")
    end

    test "refreshes when a server is added elsewhere", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      {:ok, _} = ServerManager.add_server(ProxyServer.socks5("late-arrival", "127.0.0.1", 1099))
      Phoenix.PubSub.broadcast(PpClient.PubSub, "servers", {:server_updated, nil})

      assert has_element?(view, "#profile_schema_servers option[value='late-arrival']")
    end
  end

  describe "Real-time Updates" do
    test "receives profile updates via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles")

      # Create the profile from another process
      profile = %ProxyProfile{
        name: "pubsub-test",
        type: :direct,
        enabled: true,
        servers: []
      }

      ProfileManager.add_profile(profile)

      # Broadcast the update
      Phoenix.PubSub.broadcast(PpClient.PubSub, "profiles", {:profile_updated, nil})

      # Give the LiveView time to handle the message
      :timer.sleep(100)

      html = render(view)
      assert html =~ "pubsub-test"
    end
  end
end
