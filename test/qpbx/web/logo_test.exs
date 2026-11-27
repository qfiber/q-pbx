defmodule QPBX.Web.LogoTest do
  use QPBX.Web.ConnCase, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias QPBX.Web.Logo

  test "the login page shows the logo, and every page links the favicons", %{conn: conn} do
    html = conn |> get(~p"/login") |> html_response(200)
    assert html =~ ~s(class="qpbx-logo h-20 w-auto")
    assert html =~ ~s(id="home-logo")
    assert html =~ ~s(href="/images/logo-mark.svg")
    assert html =~ ~s(href="/favicon.ico")
  end

  test "the logo component draws the three hexagons and the name from the SVG file" do
    html = render_component(&Logo.logo/1, [])
    assert length(Regex.scan(~r/<path /, html)) == 4
    mark = render_component(&Logo.logo/1, mark_only: true)
    assert length(Regex.scan(~r/<path /, mark)) == 3
    assert mark =~ ~s(viewBox="0 0 193.6 223.51")
  end
end
