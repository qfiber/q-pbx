defmodule QPBX.Web.Api.Schemas do
  @moduledoc """
  Records as JSON and their OpenAPI schemas, both derived from the Ecto schema, so a new
  field shows up in the API and its document together. Secrets are never rendered: redacted
  fields and the names in `@hidden`. Loaded has-many and has-one associations are nested;
  belongs-to ones appear as their `_id`.
  """
  alias QPBX.Core.{ApiKey, Device, OutboundRoute, User}

  @hidden ~w(hashed_password password totp_secret totp_last_used_at token_hash ha1 pin pin_hash
             file_key recording_key push_token expires_in fingerprint)a

  # Values a schema adds to its fields.
  defp extras(%Device{sip_credential: %{username: u}}), do: %{sip_username: u}
  defp extras(%User{user_role: %{role: role}}), do: %{role: role}
  defp extras(%ApiKey{tenant_id: tid}), do: %{kind: if(tid, do: "tenant", else: "platform")}
  defp extras(%OutboundRoute{trunk_ids: ids}), do: %{trunk_ids: ids}
  defp extras(_), do: %{}

  @extra_props %{
    Device => %{sip_username: %{type: ["string", "null"]}},
    User => %{role: %{type: "string", enum: ["tenant_admin", "tenant_user"]}},
    ApiKey => %{kind: %{type: "string", enum: ["tenant", "platform"]}},
    OutboundRoute => %{
      trunk_ids: %{
        type: "array",
        items: %{type: "string", format: "uuid"},
        description: "failover order"
      }
    }
  }

  # Nested records that are not exposed on their own.
  @skip_assocs [:user_role, :route_trunks, :sip_credential]

  def render(list) when is_list(list), do: Enum.map(list, &render/1)

  def render(%mod{} = rec) when mod not in [DateTime, Date, NaiveDateTime] do
    if function_exported?(mod, :__schema__, 1) do
      fields = Enum.map(shown(mod), &{&1, render(Map.get(rec, &1))})

      assocs =
        for a <- many(mod), loaded?(Map.get(rec, a)), do: {a, render(Map.get(rec, a))}

      Map.new(fields ++ assocs) |> Map.merge(extras(rec))
    else
      rec
    end
  end

  def render(other), do: other

  @doc "The OpenAPI schema of a record type; `name` makes it a named component."
  def of(mod, name \\ nil, depth \\ 1) do
    props =
      for(f <- shown(mod), into: %{}, do: {f, type(mod.__schema__(:type, f))})
      |> Map.merge(Map.get(@extra_props, mod, %{}))

    props = if depth > 0, do: Map.merge(props, nested(mod, depth)), else: props

    schema = %{type: "object", properties: props}
    if name, do: Map.put(schema, :"x-name", name), else: schema
  end

  defp nested(mod, depth) do
    Map.new(many(mod), fn a ->
      %{cardinality: c, related: rel} = mod.__schema__(:association, a)
      inner = of(rel, nil, depth - 1)
      {a, if(c == :many, do: %{type: "array", items: inner}, else: inner)}
    end)
  end

  @doc "A request body: the record's fields without ids, timestamps or the tenant."
  def input(mod, name, required \\ [], extra \\ %{}) do
    props =
      Map.drop(of(mod, nil, 0).properties, [:id, :tenant_id, :inserted_at, :updated_at, :edge_id])
      |> Map.merge(extra)

    %{"x-name": name, type: "object", properties: props}
    |> then(&if(required == [], do: &1, else: Map.put(&1, :required, required)))
  end

  defp shown(mod),
    do:
      (mod.__schema__(:fields) -- mod.__schema__(:redact_fields))
      |> Enum.reject(&(&1 in @hidden))

  defp many(mod) do
    for a <- mod.__schema__(:associations),
        a not in @skip_assocs,
        match?(
          %{cardinality: _, __struct__: s} when s != Ecto.Association.BelongsTo,
          mod.__schema__(:association, a)
        ),
        do: a
  end

  defp loaded?(%Ecto.Association.NotLoaded{}), do: false
  defp loaded?(_), do: true

  defp type(t) when t in [:binary_id, Ecto.UUID], do: %{type: "string", format: "uuid"}

  defp type(t) when t in [:utc_datetime, :utc_datetime_usec, :naive_datetime],
    do: %{type: "string", format: "date-time"}

  defp type(:date), do: %{type: "string", format: "date"}
  defp type(:integer), do: %{type: "integer"}
  defp type(:boolean), do: %{type: "boolean"}
  defp type(:map), do: %{type: "object"}
  defp type({:array, t}), do: %{type: "array", items: type(t)}
  defp type(_), do: %{type: "string"}

  def error,
    do: %{
      "x-name": "Error",
      type: "object",
      required: ["error"],
      properties: %{
        error: %{
          type: "object",
          required: ["code", "message"],
          properties: %{
            code: %{type: "string", example: "not_found"},
            message: %{type: "string"},
            details: %{type: "object"}
          }
        }
      }
    }
end
