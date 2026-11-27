defmodule QPBX.Web.StaticTest do
  use QPBX.Web.ConnCase, async: true

  test "the theme script is served under its fingerprinted name too" do
    digest = "theme-" <> String.duplicate("a", 32) <> ".js"
    dir = Application.app_dir(:qpbx, "priv/static")
    path = Path.join(dir, digest)
    File.write!(path, "// theme")
    on_exit(fn -> File.rm(path) end)
    assert build_conn() |> get("/" <> digest) |> response(200) == "// theme"
  end
end
