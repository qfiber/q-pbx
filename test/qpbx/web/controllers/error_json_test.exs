defmodule QPBX.Web.ErrorJSONTest do
  use QPBX.Web.ConnCase, async: true
  alias QPBX.Web.ErrorJSON

  test "renders 404 in the API's error format" do
    assert ErrorJSON.render("404.json", %{}) ==
             %{error: %{code: "not_found", message: "Not Found."}}
  end

  test "renders 500" do
    assert ErrorJSON.render("500.json", %{}) ==
             %{error: %{code: "server_error", message: "Internal Server Error."}}
  end
end
