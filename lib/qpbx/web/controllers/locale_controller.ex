defmodule QPBX.Web.LocaleController do
  use QPBX.Web, :controller

  def update(conn, %{"locale" => locale}) do
    conn =
      if locale in QPBX.Web.Locale.codes(), do: put_session(conn, :locale, locale), else: conn

    redirect(conn, to: back_path(conn))
  end

  # Only same-site paths, so the switch cannot be used as an open redirect.
  defp back_path(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{host: host, path: "/" <> rest = path} <- URI.parse(referer),
         false <- String.starts_with?(rest, "/"),
         true <- host in [nil, conn.host] do
      path
    else
      _ -> ~p"/login"
    end
  end
end
