defmodule QPBX.Web.Api.Idempotency do
  @moduledoc """
  Controller plug for POSTs with an `Idempotency-Key` header (up to 255 characters): the
  first request runs and its response is kept 24 hours; a retry with the same key and the
  same request gets that response again (header `idempotent-replayed: true`) without running
  twice. Server errors (5xx) are not kept, so they can be retried.
  """
  @behaviour Plug
  import Plug.Conn
  alias QPBX.Core
  alias QPBX.Web.Api.Error

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    case get_req_header(conn, "idempotency-key") do
      [] ->
        conn

      [key | _] when byte_size(key) in 1..255 ->
        run(conn, key)

      _ ->
        Error.send(
          conn,
          400,
          "bad_idempotency_key",
          "Idempotency-Key must be 1 to 255 characters."
        )
    end
  end

  def call(conn, _opts), do: conn

  defp run(conn, key) do
    api_key = conn.assigns.api_key

    case Core.idempotency_claim(api_key, key, fingerprint(conn)) do
      :claimed ->
        register_before_send(conn, fn conn ->
          :ok =
            Core.idempotency_finish(
              api_key,
              key,
              conn.status,
              IO.iodata_to_binary(conn.resp_body)
            )

          conn
        end)

      {:replay, status, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("idempotent-replayed", "true")
        |> send_resp(status, body)
        |> halt()

      :in_progress ->
        Error.send(
          conn,
          409,
          "idempotency_in_progress",
          "A request with this Idempotency-Key is still running."
        )

      :mismatch ->
        Error.send(
          conn,
          422,
          "idempotency_key_reused",
          "This Idempotency-Key was used for a different request."
        )
    end
  end

  # The same key may only repeat the same request: method, path and body.
  defp fingerprint(conn),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({conn.method, conn.request_path, conn.body_params}, [
          :deterministic
        ])
      )
end
