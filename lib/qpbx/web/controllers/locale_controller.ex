defmodule QPBX.Web.LocaleController do
  use QPBX.Web, :controller

  def update(conn, %{"locale" => locale}) when locale in ["en", "ar"] do
    conn |> put_session(:locale, locale) |> redirect(to: back_path(conn))
  end

  def update(conn, _params), do: redirect(conn, to: back_path(conn))

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
