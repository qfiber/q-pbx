defmodule QPBX.Web.HealthControllerTest do
  use QPBX.Web.ConnCase, async: false
  alias QPBX.Web.Health

  defp set(components) do
    comps = Map.new(components, fn {k, s} -> {k, %{status: s, detail: "x"}} end)
    Health.put(%{status: Health.overall(comps), components: comps, checked_at: nil})
  end

  test "GET /health is 200 ok with no details", %{conn: conn} do
    set(postgres: :ok)
    conn = get(conn, ~p"/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /health is 503 when degraded or down", %{conn: conn} do
    set(postgres: :ok, disk: :warning)
    assert json_response(get(conn, ~p"/health"), 503) == %{"status" => "degraded"}
    set(postgres: :error)
    assert json_response(get(build_conn(), ~p"/health"), 503) == %{"status" => "down"}
  end

  test "GET /health/details needs the bearer token", %{conn: conn} do
    set(postgres: :ok, disk: :ok)
    assert json_response(get(conn, ~p"/health/details"), 401)

    bad =
      build_conn() |> put_req_header("authorization", "Bearer wrong") |> get(~p"/health/details")

    assert json_response(bad, 401)

    good =
      build_conn()
      |> put_req_header(
        "authorization",
        "Bearer " <> Application.fetch_env!(:qpbx, :health_token)
      )
      |> get(~p"/health/details")

    body = json_response(good, 200)
    assert body["components"]["postgres"]["status"] == "ok"
  end
end
