defmodule QPBX.Web.Api.AuditController do
  @moduledoc "The audit log: a tenant key reads its tenant's, a platform key all (or one tenant's)."
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Core.AuditLog

  def operation(:index),
    do:
      op("Audit log", "Audit entries, newest first", "read", :any,
        params:
          Page.params() ++
            [
              query("tenant_id", "platform keys: one tenant's entries", %{
                type: "string",
                format: "uuid"
              })
            ],
        response: {:list, Schemas.of(AuditLog, "AuditEntry")}
      )

  def index(conn, params) do
    with {:ok, limit, before} <- Page.keyset(params) |> bad_request() do
      rows =
        case conn.assigns.current_scope do
          %{kind: :tenant} = scope ->
            Core.list_my_audit_logs(scope, limit + 1, before)

          _ ->
            Core.list_audit_logs(
              [limit: limit + 1, before: before] ++ tenant(params["tenant_id"])
            )
        end

      {page, next} = Page.next(rows, limit, :inserted_at)
      json(conn, %{data: Schemas.render(page), next_cursor: next})
    end
  end

  defp tenant(nil), do: []

  defp tenant(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> [tenant_id: id]
      :error -> [tenant_id: Ecto.UUID.generate()]
    end
  end

  defp bad_request({:error, message}) when is_binary(message),
    do: {:error, {:bad_request, message}}

  defp bad_request(ok), do: ok
end
