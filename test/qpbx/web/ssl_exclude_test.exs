defmodule QPBX.Web.SSLExcludeTest do
  use ExUnit.Case, async: true
  import Plug.Test
  alias QPBX.Web.SSLExclude

  test "localhost stays on HTTP, everything else is redirected" do
    assert SSLExclude.excluded?(conn(:get, "http://localhost/health"))
    refute SSLExclude.excluded?(conn(:get, "http://portal.example.com/login"))
  end
end
