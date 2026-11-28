defmodule QPBX.Web.Api.Fallback do
  @moduledoc "Turns an API action's `{:error, _}` into the API's error format."
  use Phoenix.Controller, formats: [:json]
  alias QPBX.Web.Api.Error

  def call(conn, {:error, %Ecto.Changeset{} = cs}),
    do:
      Error.send(
        conn,
        422,
        "invalid",
        "The request has invalid fields.",
        Error.changeset_details(cs)
      )

  def call(conn, nil), do: Error.send(conn, 404, "not_found", "Not found.")
  def call(conn, {:error, :not_found}), do: Error.send(conn, 404, "not_found", "Not found.")

  def call(conn, {:error, {:bad_request, message}}),
    do: Error.send(conn, 400, "bad_request", message)

  # An outside service (the mail server) refused: the reason in plain words.
  def call(conn, {:error, {:bad_gateway, message}}),
    do: Error.send(conn, 502, "upstream_failed", message)

  def call(conn, {:error, reason}) when is_atom(reason),
    do: Error.send(conn, 422, Atom.to_string(reason), "The request was refused (#{reason}).")
end
