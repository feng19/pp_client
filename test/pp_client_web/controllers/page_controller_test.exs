defmodule PpClientWeb.PageControllerTest do
  use PpClientWeb.ConnCase

  test "GET / redirects to the admin conditions page", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/admin/conditions"
  end
end
