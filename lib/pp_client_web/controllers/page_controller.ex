defmodule PpClientWeb.PageController do
  use PpClientWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/admin/conditions")
  end
end
