defmodule QPBX.Web.AcmeControllerTest do
  use QPBX.Web.ConnCase, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "qpbx-acme-#{System.unique_integer([:positive])}")
    dir = Path.join([root, ".well-known", "acme-challenge"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "tok_ABCDEFGHIJKLMNOP"), "tok_ABCDEFGHIJKLMNOP.thumbprint")
    File.write!(Path.join(root, "secret.txt"), "nope")
    Application.put_env(:qpbx, :acme_webroot, root)

    on_exit(fn ->
      Application.delete_env(:qpbx, :acme_webroot)
      File.rm_rf!(root)
    end)
  end

  test "serves an existing challenge token", %{conn: conn} do
    conn = get(conn, "/.well-known/acme-challenge/tok_ABCDEFGHIJKLMNOP")
    assert response(conn, 200) == "tok_ABCDEFGHIJKLMNOP.thumbprint"
  end

  test "404 for unknown, malformed or path-escaping tokens", %{conn: conn} do
    for path <- [
          "/.well-known/acme-challenge/missing_token_12345",
          "/.well-known/acme-challenge/..%2Fsecret.txt",
          "/.well-known/acme-challenge/short"
        ] do
      assert response(get(conn, path), 404) == ""
    end
  end

  test "404 when no webroot is configured", %{conn: conn} do
    Application.delete_env(:qpbx, :acme_webroot)
    assert response(get(conn, "/.well-known/acme-challenge/tok_ABCDEFGHIJKLMNOP"), 404)
  end
end
