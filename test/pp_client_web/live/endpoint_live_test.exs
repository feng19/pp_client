defmodule PpClientWeb.EndpointLiveTest do
  use PpClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PpClient.EndpointManager

  setup do
    # Clean out the test environment
    :ets.delete_all_objects(:endpoints)
    :ok
  end

  describe "Index" do
    test "displays endpoint list page", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/admin/endpoints")

      assert html =~ "Endpoints"
      assert html =~ "Manage the local proxy listeners"
    end

    test "displays empty state when no endpoints", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/admin/endpoints")

      assert html =~ "No endpoints yet"
    end

    test "displays existing endpoints", %{conn: conn} do
      # Create a test endpoint
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
      # Create several test endpoints
      endpoint1 = %PpClient.Endpoint{port: 1080, type: :socks5, ip: {127, 0, 0, 1}, enable: true}
      endpoint2 = %PpClient.Endpoint{port: 8080, type: :http, ip: {127, 0, 0, 1}, enable: true}

      :ets.insert(:endpoints, {endpoint1.port, endpoint1})
      :ets.insert(:endpoints, {endpoint2.port, endpoint2})

      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      # Search for port 1080
      html =
        index_live
        |> form("form", %{search: "1080"})
        |> render_change()

      assert html =~ "1080"
      # The desktop table must not contain 8080
      assert html =~ ~r/<tbody id="endpoints"[^>]*>.*1080.*<\/tbody>/s
      refute html =~ ~r/<tbody id="endpoints"[^>]*>.*8080.*<\/tbody>/s
    end

    test "can filter endpoints by status", %{conn: conn} do
      # Create one enabled and one disabled endpoint
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

      # Filter by enabled
      html =
        index_live
        |> element("button", "Enabled")
        |> render_click()

      assert html =~ "1080"
      # Check the desktop table
      assert html =~ ~r/<tbody id="endpoints"[^>]*>.*1080.*<\/tbody>/s
      refute html =~ ~r/<tbody id="endpoints"[^>]*>.*8080.*<\/tbody>/s

      # Filter by disabled
      html =
        index_live
        |> element("button", "Disabled")
        |> render_click()

      assert html =~ "8080"
      # Check the desktop table
      refute html =~ ~r/<tbody id="endpoints"[^>]*>.*1080.*<\/tbody>/s
      assert html =~ ~r/<tbody id="endpoints"[^>]*>.*8080.*<\/tbody>/s
    end

    test "shows new endpoint form when clicking new button", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      html =
        index_live
        |> element("button", "New Endpoint")
        |> render_click()

      assert html =~ "new-endpoint-row"
      assert html =~ "Not created"
    end

    test "creates new endpoint with inline form", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      # Click the new button to reveal the form
      index_live
      |> element("button", "New Endpoint")
      |> render_click()

      # Submit the new endpoint form
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

      # The endpoint was created
      assert {:ok, endpoint} = EndpointManager.get_endpoint(9999)
      assert endpoint.port == 9999
      assert endpoint.type == :socks5
      assert endpoint.ip == {127, 0, 0, 1}
      assert endpoint.enable == true
    end

    test "can cancel new endpoint form", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/admin/endpoints")

      # Click the new button to reveal the form
      html =
        index_live
        |> element("button", "New Endpoint")
        |> render_click()

      assert html =~ "new-endpoint-row"

      # Cancel: use the desktop form selector
      index_live
      |> element("#new-endpoint-form button[phx-click='cancel_new']")
      |> render_click()

      # show_new_form flipped back to false
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

      # Edit mode should render the form elements
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

      # Start editing with the desktop button
      index_live
      |> element("#endpoints button[phx-click='start_edit'][phx-value-port='1080']")
      |> render_click()

      # Submit the edit
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

      # The change took effect
      assert {:ok, updated} = EndpointManager.get_endpoint(1081)
      assert updated.port == 1081
      assert updated.type == :http
      assert updated.ip == {127, 0, 0, 2}
      assert updated.enable == false

      # The old port is gone
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

      # Start editing with the desktop button
      index_live
      |> element("#endpoints button[phx-click='start_edit'][phx-value-port='1080']")
      |> render_click()

      # Cancel the edit with the button inside the form
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

      assert html =~ "Confirm deletion"
      assert html =~ "Delete the endpoint on port"
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

      # Open the delete dialog with the desktop button
      index_live
      |> element("#endpoints button[phx-click='delete_confirm'][phx-value-port='1080']")
      |> render_click()

      # Cancel the deletion
      html =
        index_live
        |> element("button[phx-click='delete_cancel']")
        |> render_click()

      # The endpoint is still there
      assert {:ok, _} = EndpointManager.get_endpoint(1080)
      refute html =~ "Confirm deletion"
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

      # Open the delete dialog with the desktop button
      index_live
      |> element("#endpoints button[phx-click='delete_confirm'][phx-value-port='1080']")
      |> render_click()

      # Confirm the deletion
      index_live
      |> element("button[phx-click='delete'][phx-value-port='1080']")
      |> render_click()

      # The endpoint is gone
      assert {:error, :not_found} = EndpointManager.get_endpoint(1080)
    end
  end
end
