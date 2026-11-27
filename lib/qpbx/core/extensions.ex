defmodule QPBX.Core.Extensions do
  @moduledoc """
  Extensions and their devices, in a tenant scope. Creating an extension checks the plan's
  `max_extensions` under a lock on the tenant row, so parallel requests cannot pass it. A
  device gets its own SIP login `<extension>-<label>` whose password is returned once.
  """
  import Ecto.Query
  alias QPBX.Core.{Audit, Changes, Device, Extension, Scope, SipCredentials, Tenant}
  alias QPBX.Repo

  def list(%Scope{kind: :tenant, tenant_id: tid} = scope) do
    Scope.run(scope, fn ->
      Repo.all(
        from e in Extension,
          where: e.tenant_id == ^tid,
          order_by: e.number,
          preload: [devices: :sip_credential]
      )
    end)
  end

  def get!(%Scope{kind: :tenant, tenant_id: tid} = scope, id) do
    Scope.run(scope, fn ->
      Repo.one!(
        from e in Extension,
          where: e.id == ^id and e.tenant_id == ^tid,
          preload: [devices: :sip_credential]
      )
    end)
  end

  def change(%Extension{} = ext \\ %Extension{}, attrs \\ %{}),
    do: Extension.changeset(ext, attrs)

  def create(%Scope{kind: :tenant, tenant_id: tid} = scope, attrs, actor) do
    Scope.run(scope, fn ->
      tenant = Repo.one!(from t in Tenant, where: t.id == ^tid, lock: "FOR UPDATE")
      cs = Extension.changeset(%Extension{tenant_id: tid}, attrs)

      with :ok <- within_limit(tenant, cs) do
        Changes.insert(cs, actor, "extension.create")
      end
    end)
    |> changed(tid, "extensions")
  end

  def update(
        %Scope{kind: :tenant, tenant_id: tid} = scope,
        %Extension{tenant_id: tid} = ext,
        attrs,
        actor
      ) do
    Scope.run(scope, fn ->
      ext |> Extension.changeset(attrs) |> Changes.update(actor, "extension.update")
    end)
    |> changed(tid, "extensions")
  end

  @doc "Deletes the extension, its devices and their SIP logins."
  def delete(
        %Scope{kind: :tenant, tenant_id: tid} = scope,
        %Extension{tenant_id: tid} = ext,
        actor
      ) do
    {:ok, _} =
      Scope.run(scope, fn ->
        ext = Repo.preload(ext, [devices: :sip_credential], force: true)
        Repo.delete!(ext)
        for d <- ext.devices, do: SipCredentials.remove(d.sip_credential, actor)
        Repo.insert!(Audit.entry(actor, "extension.delete", ext, %{number: ext.number}))
        {:ok, ext}
      end)
      |> changed(tid, "extensions")

    SipCredentials.announce(tid)
    {:ok, ext}
  end

  ## Devices

  def change_device(attrs \\ %{}), do: Device.changeset(%Device{}, attrs)

  @doc "Adds a device with its own SIP login. Returns `{:ok, device, password}`."
  def add_device(
        %Scope{kind: :tenant, tenant_id: tid} = scope,
        %Extension{tenant_id: tid} = ext,
        attrs,
        actor
      ) do
    result =
      Scope.run(scope, fn ->
        cs = Device.changeset(%Device{tenant_id: tid, extension_id: ext.id}, attrs)

        with {:ok, _} <- Ecto.Changeset.apply_action(cs, :insert),
             label = Ecto.Changeset.get_field(cs, :label),
             {:ok, cred, password} <-
               SipCredentials.insert(tid, %{username: "#{ext.number}-#{label}"}, actor)
               |> label_taken(cs),
             {:ok, device} <-
               cs |> Ecto.Changeset.put_change(:sip_credential_id, cred.id) |> Repo.insert() do
          Repo.insert!(
            Audit.entry(actor, "device.create", device, %{label: device.label, kind: device.kind})
          )

          {:ok, %{device | sip_credential: cred}, password}
        end
      end)

    with {:ok, _, _} <- result do
      SipCredentials.announce(tid)
      changed({:ok, nil}, tid, "devices")
    end

    result
  end

  def delete_device(%Scope{kind: :tenant, tenant_id: tid} = scope, device_id, actor) do
    device =
      Scope.run(scope, fn ->
        device =
          Repo.one!(
            from d in Device,
              where: d.id == ^device_id and d.tenant_id == ^tid,
              preload: :sip_credential
          )

        Repo.delete!(device)
        SipCredentials.remove(device.sip_credential, actor)
        Repo.insert!(Audit.entry(actor, "device.delete", device, %{label: device.label}))
        device
      end)

    SipCredentials.announce(tid)
    changed({:ok, device}, tid, "devices")
  end

  @doc "A new SIP password for a device; the old one stops working at once."
  def reset_device_password(%Scope{kind: :tenant, tenant_id: tid} = scope, device_id, actor) do
    device =
      Scope.run(scope, fn ->
        Repo.one!(from d in Device, where: d.id == ^device_id and d.tenant_id == ^tid)
      end)

    {:ok, _cred, password} = SipCredentials.reset_password(scope, device.sip_credential_id, actor)
    {:ok, device, password}
  end

  ## Helpers

  defp within_limit(tenant, cs) do
    case QPBX.Core.effective_limits(tenant)[:max_extensions] do
      nil ->
        :ok

      max ->
        count = Repo.aggregate(from(e in Extension, where: e.tenant_id == ^tenant.id), :count)

        if count < max,
          do: :ok,
          else:
            {:error,
             Ecto.Changeset.add_error(cs, :number, "the plan allows %{max} extensions", max: max)}
    end
  end

  # The SIP username is derived from the label: a clash means the label is taken.
  defp label_taken({:error, %Ecto.Changeset{}}, cs),
    do: {:error, Ecto.Changeset.add_error(cs, :label, "already used on this extension")}

  defp label_taken(ok, _cs), do: ok

  defp changed(result, tid, kind), do: Changes.announce(result, tid, kind)
end
