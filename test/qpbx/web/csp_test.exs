defmodule QPBX.Web.CSPTest do
  use QPBX.Web.ConnCase, async: true
  alias QPBX.Web.CSP

  test "portal pages carry a strict policy without inline scripts", %{conn: conn} do
    [policy] = get(conn, ~p"/login") |> get_resp_header("content-security-policy")
    assert policy =~ "script-src 'self';"
    refute policy =~ "unsafe-inline';" and policy =~ "script-src 'self' 'unsafe-inline'"
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "form-action 'self'"
  end

  test "only the configured provider's domains are allowed" do
    assert CSP.policy(:turnstile) =~ "script-src 'self' https://challenges.cloudflare.com"
    assert CSP.policy(:turnstile) =~ "frame-src https://challenges.cloudflare.com"
    refute CSP.policy(:pow) =~ "cloudflare"
    assert CSP.policy(:pow) =~ "frame-src 'none'"
    assert CSP.policy(:friendly_captcha) =~ "connect-src 'self' https://global.frcapi.com"
  end

  test "the page has no inline script", %{conn: conn} do
    html = get(conn, ~p"/login") |> html_response(200)
    refute html =~ ~r/<script>(?!<\/script>)/
    assert html =~ ~s(src="/theme.js")
  end
end
