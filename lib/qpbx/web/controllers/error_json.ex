defmodule QPBX.Web.ErrorJSON do
  @moduledoc """
  Errors raised while answering a JSON request (for example a record that is not found or a
  malformed id), in the API's error format (`QPBX.Web.Api.Error`).
  """
  alias QPBX.Web.Api.Error

  def render(template, _assigns) do
    status = template |> String.split(".") |> hd()
    message = Phoenix.Controller.status_message_from_template(template)
    Error.body(code(status), message <> ".")
  end

  defp code("400"), do: "bad_request"
  defp code("404"), do: "not_found"
  defp code("406"), do: "not_acceptable"
  defp code("415"), do: "unsupported_media_type"
  defp code(status) when status >= "500", do: "server_error"
  defp code(_), do: "error"
end
