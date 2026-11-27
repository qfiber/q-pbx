defmodule QPBX.Web.SSLExcludeTest do
  use ExUnit.Case, async: true
  import Plug.Test
  alias QPBX.Web.SSLExclude

  test "ACME challenges and localhost stay on HTTP, everything else is redirected" do
    assert SSLExclude.excluded?(
             conn(:get, "http://portal.example.com/.well-known/acme-challenge/abc")
           )

    assert SSLExclude.excluded?(conn(:get, "http://localhost/health"))
    refute SSLExclude.excluded?(conn(:get, "http://portal.example.com/login"))
    refute SSLExclude.excluded?(conn(:get, "http://portal.example.com/.well-known/other"))
  end
end
