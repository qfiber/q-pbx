defmodule QPBX.Core.SipCredentials do
  @moduledoc """
  SIP digest credentials: created and reset with a generated password returned once, stored
  as HA1 only. Every change is audited and announced (`SipCredentialsChanged`), so Kamailio
  reloads its in-memory copy at once.
  """
  import Ecto.Query
  alias QPBX.Core.{Audit, Scope, SipCredential, Tenant}
  alias QPBX.Events
  alias QPBX.Events.SipCredentialsChanged
  alias QPBX.Repo

  def list(%Scope{kind: :tenant, tenant_id: tid} = scope),
    do:
      Scope.run(scope, fn ->
        Repo.all(from c in SipCredential, where: c.tenant_id == ^tid, order_by: c.username)
      end)

  @doc "Creates a credential. Returns `{:ok, credential, password}`; the password is not kept."
  def create(%Scope{kind: :tenant, tenant_id: tid} = scope, attrs, actor) do
    tenant = Repo.get!(Tenant, tid)
    password = SipCredential.generate_password()
    cs = SipCredential.changeset(%SipCredential{tenant_id: tid}, attrs)

    cs =
      Ecto.Changeset.put_change(
        cs,
        :ha1,
        SipCredential.ha1(Ecto.Changeset.get_field(cs, :username), tenant.sip_domain, password)
      )

    result =
      Scope.run(scope, fn ->
        with {:ok, cred} <- Repo.insert(cs),
             {:ok, _} <-
               Repo.insert(
                 Audit.entry(actor, "sip_credential.create", cred, %{username: cred.username})
               ) do
          {:ok, cred}
        end
      end)

    with {:ok, cred} <- result do
      announce(tid)
      {:ok, cred, password}
    end
  end

  @doc "A new password for an existing credential; the old one stops working at once."
  def reset_password(%Scope{kind: :tenant, tenant_id: tid} = scope, id, actor) do
    tenant = Repo.get!(Tenant, tid)
    password = SipCredential.generate_password()

    result =
      Scope.run(scope, fn ->
        cred = Repo.one!(from c in SipCredential, where: c.id == ^id and c.tenant_id == ^tid)

        {:ok, cred} =
          cred
          |> Ecto.Changeset.change(
            ha1: SipCredential.ha1(cred.username, tenant.sip_domain, password)
          )
          |> Repo.update()

        {:ok, _} = Repo.insert(Audit.entry(actor, "sip_credential.reset_password", cred, %{}))
        cred
      end)

    announce(tid)
    {:ok, result, password}
  end

  def delete(%Scope{kind: :tenant, tenant_id: tid} = scope, id, actor) do
    result =
      Scope.run(scope, fn ->
        cred = Repo.one!(from c in SipCredential, where: c.id == ^id and c.tenant_id == ^tid)
        {:ok, cred} = Repo.delete(cred)

        {:ok, _} =
          Repo.insert(
            Audit.entry(actor, "sip_credential.delete", cred, %{username: cred.username})
          )

        cred
      end)

    announce(tid)
    {:ok, result}
  end

  defp announce(tenant_id),
    do: Events.publish(%SipCredentialsChanged{tenant_id: tenant_id, at: DateTime.utc_now()})
end
