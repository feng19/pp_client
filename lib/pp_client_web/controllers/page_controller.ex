defmodule PpClientWeb.PageController do
  use PpClientWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
