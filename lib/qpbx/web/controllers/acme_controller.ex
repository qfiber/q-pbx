defmodule QPBX.Web.AcmeController do
  @moduledoc """
  Answers ACME HTTP-01 challenges (per-hostname certificate mode) from the webroot that
  acme.sh writes to: `<webroot>/.well-known/acme-challenge/<token>`.
  """
  use QPBX.Web, :controller

  # ACME tokens are base64url; anything else could be a path trick.
  @token ~r/\A[A-Za-z0-9_-]{16,128}\z/

  def show(conn, %{"token" => token}) do
    with root when is_binary(root) <- Application.get_env(:qpbx, :acme_webroot),
         true <- Regex.match?(@token, token),
         path = Path.join([root, ".well-known", "acme-challenge", token]),
         {:ok, body} <- File.read(path) do
      conn |> put_resp_content_type("text/plain") |> send_resp(200, body)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
