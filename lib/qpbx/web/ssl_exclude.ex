defmodule QPBX.Web.SSLExclude do
  @moduledoc "Requests that stay on plain HTTP: ACME HTTP-01 challenges and localhost (health checks)."

  def excluded?(%Plug.Conn{path_info: [".well-known", "acme-challenge" | _]}), do: true
  def excluded?(%Plug.Conn{host: host}), do: host in ["localhost", "127.0.0.1", "::1"]
end
