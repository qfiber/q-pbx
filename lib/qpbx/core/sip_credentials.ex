defmodule QPBX.Core.SipCredentials do
  @moduledoc """
  SIP digest credentials: created and reset with a generated password returned once, stored
  as HA1 only. Every change is audited and announced (`SipCredentialsChanged`) after its
  commit, so Kamailio reloads its in-memory copy at once.
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
    with {:ok, cred, password} <- Scope.run(scope, fn -> insert(tid, attrs, actor) end) do
      announce(tid)
      {:ok, cred, password}
    end
  end

  @doc "A new password for an existing credential; the old one stops working at once."
  def reset_password(%Scope{kind: :tenant, tenant_id: tid} = scope, id, actor) do
    domain = domain(tid)
    password = SipCredential.generate_password()

    cred =
      Scope.run(scope, fn ->
        cred = Repo.one!(from c in SipCredential, where: c.id == ^id and c.tenant_id == ^tid)

        cred =
          cred
          |> Ecto.Changeset.change(ha1: SipCredential.ha1(cred.username, domain, password))
          |> Repo.update!()

        Repo.insert!(Audit.entry(actor, "sip_credential.reset_password", cred, %{}))
        cred
      end)

    announce(tid)
    {:ok, cred, password}
  end

  def delete(%Scope{kind: :tenant, tenant_id: tid} = scope, id, actor) do
    cred =
      Scope.run(scope, fn ->
        remove(
          Repo.one!(from c in SipCredential, where: c.id == ^id and c.tenant_id == ^tid),
          actor
        )
      end)

    announce(tid)
    {:ok, cred}
  end

  @doc false
  # For Core callers that create a credential inside their own transaction (devices); they
  # call announce/1 after the commit.
  def insert(tenant_id, attrs, actor) do
    password = SipCredential.generate_password()
    cs = SipCredential.changeset(%SipCredential{tenant_id: tenant_id}, attrs)
    username = Ecto.Changeset.get_field(cs, :username)

    cs =
      Ecto.Changeset.put_change(
        cs,
        :ha1,
        SipCredential.ha1(username || "", domain(tenant_id), password)
      )

    with {:ok, cred} <- Repo.insert(cs) do
      Repo.insert!(Audit.entry(actor, "sip_credential.create", cred, %{username: cred.username}))
      {:ok, cred, password}
    end
  end

  @doc false
  def remove(%SipCredential{} = cred, actor) do
    cred = Repo.delete!(cred)
    Repo.insert!(Audit.entry(actor, "sip_credential.delete", cred, %{username: cred.username}))
    cred
  end

  @doc false
  def announce(tenant_id),
    do: Events.publish(%SipCredentialsChanged{tenant_id: tenant_id, at: DateTime.utc_now()})

  defp domain(tid), do: Repo.one!(from t in Tenant, where: t.id == ^tid, select: t.sip_domain)
end
