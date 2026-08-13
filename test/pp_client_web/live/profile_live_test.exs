defmodule PpClientWeb.ProfileLiveTest do
  use PpClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PpClient.ProfileManager
  alias PpClient.ProxyProfile
  alias PpClient.ProxyServer

  @moduletag capture_log: true

  setup do
    # Clean out the test data
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

      assert html =~ "Profiles"
      assert html =~ "direct"
    end

    test "searches profiles", %{conn: conn} do
      # Create a test profile with valid servers
      profile = %ProxyProfile{
        name: "test-profile",
        type: :remote,
        enabled: true,
        servers: [ProxyServer.socks5("127.0.0.1", 1080)]
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

      # Remove the default server first: a direct profile needs none
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

      # Switch the type to remote, which already has a default server
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "new-remote"})
      |> render_change()

      # Submit the form with the default server
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

      # Remove the default server first
      view
      |> element("button[phx-click='remove_server'][phx-value-index='0']")
      |> render_click()

      # Try to submit a remote profile with no server
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

      # The validation error shows up in the flash message
      assert html =~ "Save failed"
      assert html =~ "Remote profile must have at least one server"
      # The form is still there, no redirect happened
      assert has_element?(view, "#profile-form")
    end

    test "allows creating remote profile with servers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # Pick the remote type, which already has a default server
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "remote-with-server"})
      |> render_change()

      # Submitting with the default server should succeed
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

  describe "Server Management" do
    test "adds server to profile form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # Pick the remote type
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "test"})
      |> render_change()

      # Add a server
      html =
        view
        |> element("button[phx-click='add_server']")
        |> render_click()

      assert html =~ "Server #1"
      assert html =~ "Server type"
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

      # Remove the server
      html =
        view
        |> element("button[phx-click='remove_server'][phx-value-index='0']")
        |> render_click()

      refute html =~ "Server 1"
    end

    test "displays SOCKS5 specific fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # Pick the remote type and add a server
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "test"})
      |> render_change()

      view
      |> element("button[phx-click='add_server']")
      |> render_click()

      # SOCKS5 is the default type, so the host and port fields show up
      html = render(view)
      assert html =~ "Host"
      assert html =~ "Port"
      refute html =~ "WebSocket URI"
      refute html =~ "Password"
      refute html =~ "Encryption"
    end

    test "displays EXPS specific fields when server type changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # Pick the remote type
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "test"})
      |> render_change()

      # Change the default server type to EXPS
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

      # The EXPS specific fields show up
      assert html =~ "WebSocket URI"
      assert html =~ "Encryption"
      assert html =~ "Encryption key"
      # Note: with several servers possible, only check that the EXPS fields exist
    end

    test "displays CF Workers specific fields when server type changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/new")

      # Pick the remote type
      view
      |> form("#profile-form", profile_schema: %{type: :remote, name: "test"})
      |> render_change()

      # Change the default server type to CF Workers
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

      # The CF Workers specific fields show up
      assert html =~ "WebSocket URI"
      assert html =~ "Password"
      # Note: with several servers possible, only check that the CF Workers fields exist
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

      # The EXPS specific fields show up
      assert html =~ "WebSocket URI"
      assert html =~ "Encryption"
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

      # The CF Workers specific fields show up
      assert html =~ "WebSocket URI"
      assert html =~ "Password"
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

      # The SOCKS5 specific fields show up
      assert html =~ "Host"
      assert html =~ "Port"
      assert html =~ "192.168.1.100"
      assert html =~ "1088"
    end
  end

  describe "Credentials in LiveView state" do
    @password "sup3r-s3cret-cf-workers-password"

    setup do
      profile = %ProxyProfile{
        name: "redact-test",
        type: :remote,
        enabled: true,
        servers: [ProxyServer.cf_workers("wss://worker.example.com", @password)]
      }

      ProfileManager.add_profile(profile)
      :ok
    end

    test "the edit form still renders the stored password", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/profiles/redact-test/edit")

      assert html =~ @password
    end

    test "a crash would not print the stored password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/profiles/redact-test/edit")

      refute printed_state(view) =~ @password
    end

    test "a crash would not print a password being typed", %{conn: conn} do
      typed = "just-typed-#{@password}"

      {:ok, view, _html} = live(conn, ~p"/admin/profiles/redact-test/edit")

      html =
        view
        |> form("#profile-form",
          profile_schema: %{
            name: "redact-test",
            type: :remote,
            servers: %{
              "0" => %{
                type: "cf-workers",
                uri: "wss://worker.example.com",
                password: typed
              }
            }
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
