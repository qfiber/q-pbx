defmodule QPBX.Web.SSLExclude do
  @moduledoc "Requests that stay on plain HTTP: local health checks (nginx answers ACME challenges)."

  def excluded?(%Plug.Conn{host: host}), do: host in ["localhost", "127.0.0.1", "::1"]
end
