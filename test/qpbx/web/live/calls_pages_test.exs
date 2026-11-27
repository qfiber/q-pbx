defmodule QPBX.Web.CallsPagesTest do
  use QPBX.Web.ConnCase, async: false
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Telephony.Cdrs
  alias QPBX.Web.CallsController

  defp signed_in(conn, account) do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, ~p"/login", login: %{email: account.email, password: password()})
    conn = post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)})
    recycle(conn)
  end

  defp cdr(t, vars) do
    u = Ecto.UUID.generate()

    base = %{
      "uuid" => u,
      "call_uuid" => u,
      "direction" => "inbound",
      "qpbx_tenant" => t.id,
      "qpbx_caller" => "101",
      "caller_id_name" => "=HYPERLINK(\"x\")",
      "qpbx_destination" => "+972501234567",
      "qpbx_direction" => "outbound",
      "start_epoch" => "#{System.os_time(:second) - 100}",
      "answer_epoch" => "#{System.os_time(:second) - 95}",
      "end_epoch" => "#{System.os_time(:second) - 30}",
      "duration" => "70",
      "billsec" => "65",
      "hangup_cause" => "NORMAL_CLEARING"
    }

    Cdrs.from_json(%{"variables" => Map.merge(base, vars)})
  end

  setup %{conn: conn} do
    t = tenant_fixture()
    admin = user_fixture(t, "tenant_admin")

    Cdrs.insert_batch(
      [
        cdr(t, %{}),
        cdr(t, %{
          "qpbx_destination" => "103",
          "qpbx_direction" => "internal",
          "answer_epoch" => "0",
          "billsec" => "0",
          "hangup_cause" => "NO_ANSWER"
        })
      ],
      %{t.id => t.timezone}
    )

    %{conn: signed_in(conn, admin), t: t}
  end

  test "the call history: rows, filters, daily totals", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/app/calls")
    assert html =~ "+972501234567" and html =~ "1:05" and html =~ "Not answered"
    html = view |> form("#calls-filter", f: %{direction: "internal"}) |> render_submit()
    assert_patch(view, ~p"/app/calls?direction=internal&leg=a")
    refute html =~ "+972501234567"
    assert html =~ "103"
    {:ok, _view, html} = live(conn, ~p"/app/calls?number=5012")
    assert html =~ "+972501234567"
    refute html =~ ">103<"
    assert html =~ ~r/id="usage"/
  end

  test "CSV export: the tenant's calls, formulas neutralised; only for tenant admins", %{
    conn: conn,
    t: t
  } do
    resp = get(conn, ~p"/app/calls/export?direction=outbound")
    assert resp.status == 200
    assert get_resp_header(resp, "content-type") |> hd() =~ "text/csv"
    [header, row] = String.split(resp.resp_body, "\r\n", trim: true)
    assert header =~ "started_at,answered_at"
    assert row =~ ",outbound,a,101,\"'=HYPERLINK(\"\"x\"\")\",+972501234567,answered,"

    user = user_fixture(t, "tenant_user")
    assert get(signed_in(build_conn(), user), ~p"/app/calls/export").status == 404
    other = user_fixture(tenant_fixture(), "tenant_admin")

    [only_header] =
      String.split(get(signed_in(build_conn(), other), ~p"/app/calls/export").resp_body, "\r\n",
        trim: true
      )

    assert only_header =~ "started_at"
  end

  test "CSV cells" do
    assert CallsController.cell("+972501234567") == "+972501234567"
    assert CallsController.cell("-1") == "-1"
    assert CallsController.cell("@SUM(A1)") == "'@SUM(A1)"
    assert CallsController.cell("a,b") == "\"a,b\""
  end
end
