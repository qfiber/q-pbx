defmodule QPBX.Web.Api.FirewallController do
  @moduledoc """
  Firewall entries. Platform keys: the platform's allow and block lists (SSH, SIP, HTTPS).
  Tenant keys: the tenant's office IPs (allowed for SIP, never banned automatically).
  """
  use QPBX.Web, :api_controller
  alias QPBX.Firewall
  alias QPBX.Firewall.Entry

  @entry Schemas.of(Entry, "FirewallEntry")

  def operation(:index),
    do:
      op("Firewall", "List the platform's firewall entries", "read", :platform,
        params: Page.params(),
        response: {:list, @entry}
      )

  def operation(:create),
    do:
      op("Firewall", "Add a platform firewall entry", "write", :platform,
        body: Schemas.input(Entry, "FirewallEntryInput", ~w(kind scope cidr reason)),
        status: 201,
        response: @entry
      )

  def operation(:delete),
    do:
      op(
        "Firewall",
        "Remove a platform entry (the last management address is refused)",
        "write",
        :platform,
        response: nil
      )

  def operation(:office_ips),
    do:
      op("Office IPs", "List the tenant's office IPs", "read", :tenant,
        params: Page.params(),
        response: {:list, @entry}
      )

  def operation(:create_office_ip),
    do:
      op("Office IPs", "Add an office IP", "write", :tenant,
        body: %{
          type: "object",
          required: ["cidr", "reason"],
          properties: %{cidr: %{type: "string"}, reason: %{type: "string"}}
        },
        status: 201,
        response: @entry
      )

  def operation(:delete_office_ip),
    do: op("Office IPs", "Remove an office IP", "write", :tenant, response: nil)

  def index(conn, params), do: paged(conn, Firewall.list_entries(level: "platform"), params)

  def create(conn, params),
    do:
      reply(
        conn,
        Firewall.create_entry(Map.put(params, "level", "platform"), conn.assigns.api_key),
        201
      )

  def delete(conn, %{"id" => id}), do: remove(conn, id, &(&1.level == "platform"))

  def office_ips(conn, params),
    do:
      paged(
        conn,
        Firewall.list_entries(level: "tenant", tenant_id: conn.assigns.current_scope.tenant_id),
        params
      )

  def create_office_ip(conn, params) do
    attrs =
      params
      |> Map.take(~w(cidr reason))
      |> Map.merge(%{
        "level" => "tenant",
        "tenant_id" => conn.assigns.current_scope.tenant_id,
        "kind" => "allow",
        "scope" => "sip"
      })

    reply(conn, Firewall.create_entry(attrs, conn.assigns.api_key), 201)
  end

  def delete_office_ip(conn, %{"id" => id}),
    do:
      remove(
        conn,
        id,
        &(&1.level == "tenant" and &1.tenant_id == conn.assigns.current_scope.tenant_id)
      )

  # Only entries the key may see can be removed; others are not found.
  defp remove(conn, id, mine?) do
    entry = Firewall.get_entry!(id)

    if mine?.(entry),
      do: reply(conn, Firewall.delete_entry(entry, conn.assigns.api_key), 204),
      else: {:error, :not_found}
  end
end
