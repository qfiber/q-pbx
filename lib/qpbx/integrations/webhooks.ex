defmodule QPBX.Integrations.Webhooks do
  @moduledoc """
  Webhook endpoints (tenant scope) and their deliveries. Every bus event a tenant's endpoint
  subscribes to becomes a delivery and an Oban job in the same transaction, sent at once
  (`QPBX.Integrations.Webhooks.Worker`). Secrets are encrypted at rest and shown once (on
  creation and rotation). Changes are audited.
  """
  import Ecto.Query
  alias Ecto.Multi
  alias QPBX.Core
  alias QPBX.Core.Scope
  alias QPBX.Integrations.Webhooks.{Delivery, Endpoint, Event, Signature, Worker}
  alias QPBX.Repo

  ## Endpoints

  def list(%Scope{kind: :tenant, tenant_id: tid} = scope),
    do:
      Scope.run(scope, fn ->
        Repo.all(from e in Endpoint, where: e.tenant_id == ^tid, order_by: e.inserted_at)
      end)

  def get(%Scope{kind: :tenant, tenant_id: tid} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Scope.run(scope, fn ->
          Repo.one(from e in Endpoint, where: e.id == ^id and e.tenant_id == ^tid)
        end)

      :error ->
        nil
    end
  end

  def change(%Endpoint{} = e \\ %Endpoint{}, attrs \\ %{}), do: Endpoint.changeset(e, attrs)

  @doc "Creates an endpoint: `{:ok, endpoint, secret}`; the secret is not shown again."
  def create(%Scope{kind: :tenant, tenant_id: tid} = scope, attrs, actor) do
    secret = Signature.new_secret()

    cs =
      %Endpoint{tenant_id: tid, secret: secret}
      |> Endpoint.changeset(attrs)
      |> Endpoint.check_destination()

    Scope.run(scope, fn ->
      with {:ok, e} <- Repo.insert(cs) do
        audit(actor, "webhook.create", e, %{url: e.url, event_types: e.event_types})
        {:ok, e}
      end
    end)
    |> with_secret(secret)
  end

  def update(
        %Scope{kind: :tenant, tenant_id: tid} = scope,
        %Endpoint{tenant_id: tid} = e,
        attrs,
        actor
      ) do
    Scope.run(scope, fn ->
      cs = e |> Endpoint.changeset(attrs) |> Endpoint.check_destination()

      with {:ok, e} <- Repo.update(cs) do
        audit(actor, "webhook.update", e, cs.changes)
        {:ok, e}
      end
    end)
  end

  def delete(%Scope{kind: :tenant, tenant_id: tid} = scope, %Endpoint{tenant_id: tid} = e, actor) do
    Scope.run(scope, fn ->
      Repo.delete!(e)
      audit(actor, "webhook.delete", e, %{url: e.url})
      {:ok, e}
    end)
  end

  @doc "A new secret for an endpoint: `{:ok, endpoint, secret}`; the old one stops at once."
  def rotate_secret(
        %Scope{kind: :tenant, tenant_id: tid} = scope,
        %Endpoint{tenant_id: tid} = e,
        actor
      ) do
    secret = Signature.new_secret()

    Scope.run(scope, fn ->
      e = e |> Ecto.Changeset.change(secret: secret) |> Repo.update!()
      audit(actor, "webhook.rotate_secret", e, %{})
      {:ok, e}
    end)
    |> with_secret(secret)
  end

  defp with_secret({:ok, e}, secret), do: {:ok, e, secret}
  defp with_secret(error, _), do: error

  defp audit(actor, action, e, changes), do: {:ok, _} = Core.audit(actor, action, e, changes)

  ## Deliveries

  @doc "An endpoint's deliveries, newest first; `before: {inserted_at, id}` pages on."
  def deliveries(%Scope{kind: :tenant} = scope, %Endpoint{id: eid}, limit \\ 50, before \\ nil) do
    q =
      from d in Delivery,
        where: d.endpoint_id == ^eid,
        order_by: [desc: d.inserted_at, desc: d.id],
        limit: ^limit

    q =
      case before do
        {at, id} ->
          where(
            q,
            [d],
            fragment("(?, ?) < (?, ?)", d.inserted_at, d.id, ^at, type(^id, :binary_id))
          )

        nil ->
          q
      end

    Scope.run(scope, fn -> Repo.all(q) end)
  end

  def get_delivery(%Scope{kind: :tenant, tenant_id: tid} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Scope.run(scope, fn ->
          Repo.one(from d in Delivery, where: d.id == ^id and d.tenant_id == ^tid)
        end)

      :error ->
        nil
    end
  end

  @doc "Sends a delivery's event again (same event id) as a new delivery: `{:ok, delivery}`."
  def resend(%Scope{kind: :tenant} = scope, %Delivery{} = d, actor) do
    result =
      Scope.run(scope, fn ->
        with {:ok, %{delivery: new}} <-
               enqueue(
                 Multi.new(),
                 d.tenant_id,
                 d.endpoint_id,
                 d.event_id,
                 d.event_type,
                 d.payload
               )
               |> Repo.transaction() do
          audit(actor, "webhook.resend", new, %{event_id: d.event_id})
          {:ok, new}
        end
      end)

    case result do
      {:error, _, reason, _} -> {:error, reason}
      other -> other
    end
  end

  ## From the event bus

  @doc "Turns a bus event into deliveries for the tenant's endpoints that want it."
  def dispatch(event) do
    case Event.from(event) do
      {type, tid, data} when is_binary(tid) ->
        deliver(type, tid, data, Map.get(event, :version, 1), Map.get(event, :at))

      _ ->
        :ok
    end
  end

  defp deliver(type, tid, data, version, at) do
    endpoints =
      Repo.all(
        from e in Endpoint,
          where: e.tenant_id == ^tid and e.enabled and ^type in e.event_types,
          select: e.id
      )

    if endpoints != [] do
      id = Ecto.UUID.generate()
      body = Event.payload(id, type, version, tid, data, at || DateTime.utc_now())

      endpoints
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {eid, i}, multi ->
        enqueue(multi, tid, eid, id, type, body, i)
      end)
      |> Repo.transaction()
    end

    :ok
  end

  defp enqueue(multi, tid, eid, event_id, type, body, i \\ 0) do
    key = if i == 0, do: :delivery, else: {:delivery, i}

    multi
    |> Multi.insert(key, %Delivery{
      tenant_id: tid,
      endpoint_id: eid,
      event_id: event_id,
      event_type: type,
      payload: body
    })
    |> Oban.insert({:job, i}, fn %{^key => d} -> Worker.new(%{"delivery_id" => d.id}) end)
  end

  @doc "Deletes deliveries older than `days` (the daily prune)."
  def prune(days \\ 30) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
    {n, _} = Repo.delete_all(from d in Delivery, where: d.inserted_at < ^cutoff)
    {:ok, n}
  end
end
