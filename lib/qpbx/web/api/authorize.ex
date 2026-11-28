defmodule QPBX.Web.Api.Authorize do
  @moduledoc """
  Controller plug: lets a request through only when the key may use the action. Each API
  controller describes its actions in `operation/1` (`QPBX.Web.Api.Spec` builds the OpenAPI
  document from the same descriptions), so the documented scope is the enforced one.
  """
  @behaviour Plug
  alias QPBX.Core.ApiKey
  alias QPBX.Web.Api.Error

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    op =
      Phoenix.Controller.controller_module(conn).operation(Phoenix.Controller.action_name(conn))

    key = conn.assigns.api_key

    cond do
      not audience?(op.audience, key) ->
        Error.send(conn, 403, "wrong_key_kind", audience_message(op.audience))

      not ApiKey.allows?(key, op.scope) ->
        Error.send(conn, 403, "missing_scope", "This API key lacks the \"#{op.scope}\" scope.", %{
          required_scope: op.scope
        })

      true ->
        conn
    end
  end

  defp audience?(:any, _), do: true
  defp audience?(:tenant, key), do: not is_nil(key.tenant_id)
  defp audience?(:platform, key), do: is_nil(key.tenant_id)

  defp audience_message(:tenant), do: "This endpoint needs a tenant's API key."
  defp audience_message(:platform), do: "This endpoint needs a platform API key."
end
