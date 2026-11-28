defmodule QPBX.Web.PromptsLiveTest do
  @moduledoc "The prompt library page and API: upload, listen, remove; the system prompts."
  use QPBX.Web.ConnCase, async: true
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.{Core, Telephony}

  @wav <<"RIFF", 36::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
         8000::little-32, 16_000::little-32, 2::little-16, 16::little-16, "data", 0::little-32>>

  defp signed_in(conn, account) do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, ~p"/login", login: %{email: account.email, password: password()})
    {recycle(post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)})), account}
  end

  setup %{conn: conn} do
    t = tenant_fixture()
    {conn, admin} = signed_in(conn, user_fixture(t, "tenant_admin"))
    %{conn: conn, admin: admin, t: t}
  end

  test "upload a recording, listen to it, remove it; the system prompts are listed", %{
    conn: conn,
    admin: admin
  } do
    {:ok, view, html} = live(conn, ~p"/app/prompts")
    assert html =~ "Thank you for calling"
    refute html =~ "syphilis"

    file =
      file_input(view, "#prompt-form", :audio, [
        %{name: "main.wav", content: @wav, type: "audio/wav"}
      ])

    render_upload(file, "main.wav")
    view |> form("#prompt-form", prompt: %{name: "Main menu"}) |> render_submit()

    assert [p] = Telephony.list_prompts(Core.scope_for(admin))
    assert p.name == "Main menu"
    assert render(view) =~ "Main menu"

    assert response(get(conn, ~p"/app/prompts/#{p.id}/audio"), 200) == @wav
    assert response(get(conn, ~p"/app/prompts/system?path=../../etc/passwd"), 404)

    view |> element("#delete-#{p.id}") |> render_click()
    assert Telephony.list_prompts(Core.scope_for(admin)) == []
  end

  test "a tenant user cannot fetch prompt audio", %{conn: conn, t: t, admin: admin} do
    {:ok, p} = Telephony.upload_prompt(Core.scope_for(admin), "Hours", @wav, admin)
    {user_conn, _} = signed_in(Phoenix.ConnTest.build_conn(), user_fixture(t, "tenant_user"))
    assert response(get(user_conn, ~p"/app/prompts/#{p.id}/audio"), 404)
    assert response(get(conn, ~p"/app/prompts/#{p.id}/audio"), 200)
  end

  test "the API uploads, lists, plays and removes recordings; lists the system prompts", %{
    conn: conn,
    admin: admin
  } do
    {:ok, _, key} =
      Core.create_api_key(Core.scope_for(admin), %{name: "p", scopes: ["read", "write"]}, admin)

    api = fn -> conn |> recycle() |> put_req_header("authorization", "Bearer " <> key) end

    resp =
      api.()
      |> put_req_header("content-type", "audio/wav")
      |> post("/v1/prompts?name=After%20hours", @wav)
      |> json_response(201)

    id = resp["data"]["id"]
    assert resp["data"]["name"] == "After hours" and resp["data"]["format"] == "wav"
    refute Map.has_key?(resp["data"], "file_key")

    assert [%{"name" => "After hours"}] =
             api.() |> get("/v1/prompts") |> json_response(200) |> Map.get("data")

    assert api.() |> get("/v1/prompts/#{id}/audio") |> response(200) == @wav

    assert %{"data" => [%{"path" => "ivr/ivr-thank_you_for_calling.wav"} | _]} =
             api.() |> get("/v1/prompts/system") |> json_response(200)

    assert api.() |> delete("/v1/prompts/#{id}") |> response(204)
    assert Telephony.list_prompts(Core.scope_for(admin)) == []
  end
end
