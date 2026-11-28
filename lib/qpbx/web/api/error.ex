defmodule QPBX.Web.Api.Error do
  @moduledoc """
  The API's one error format: `{"error": {"code": ..., "message": ..., "details": ...}}`.
  `code` is stable and meant for programs; `message` is English for people.
  """
  import Plug.Conn

  @doc "Sends an error response and halts."
  def send(conn, status, code, message, details \\ nil) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body(code, message, details)))
    |> halt()
  end

  def body(code, message, details \\ nil) do
    error = %{code: code, message: message}
    %{error: if(details, do: Map.put(error, :details, details), else: error)}
  end

  @doc "Changeset errors as `%{field => [message]}`."
  def changeset_details(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
