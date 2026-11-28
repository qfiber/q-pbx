defmodule QPBX.Web.ButtonTest do
  use QPBX.Web.ConnCase, async: true

  test "the login button keeps its button styling with an extra class" do
    html = build_conn() |> get(~p"/login") |> html_response(200)
    assert html =~ ~r/<button class="btn btn-primary w-full mt-3"/
  end
end
