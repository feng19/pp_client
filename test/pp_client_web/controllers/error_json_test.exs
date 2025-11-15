defmodule PpClientWeb.ErrorJSONTest do
  use PpClientWeb.ConnCase, async: true

  test "renders 404" do
    assert PpClientWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert PpClientWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
