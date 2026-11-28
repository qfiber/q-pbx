defmodule QPBX.Web.Api.Schemas do
  @moduledoc """
  What the API returns for each record (`render/1`) and its OpenAPI schema, side by side so
  they change together. Secrets (key hashes, SIP passwords) are never rendered.
  """
  alias QPBX.Core.{ApiKey, Device, Extension, Tenant}

  @time %{type: "string", format: "date-time"}
  @id %{type: "string", format: "uuid"}
  @nullable_string %{type: ["string", "null"]}

  def render(%ApiKey{} = k),
    do: %{
      id: k.id,
      name: k.name,
      prefix: k.prefix,
      scopes: k.scopes,
      kind: if(k.tenant_id, do: "tenant", else: "platform"),
      tenant_id: k.tenant_id,
      expires_at: k.expires_at,
      created_at: k.inserted_at
    }

  def render(%Extension{} = e),
    do:
      e
      |> Map.take(
        ~w(id number name external_caller_id dnd call_waiting forward_always forward_busy
                     forward_no_answer no_answer_seconds follow_me_enabled follow_me_numbers)a
      )
      |> Map.put(:devices, Enum.map(e.devices, &render/1))

  def render(%Device{} = d),
    do: %{
      id: d.id,
      label: d.label,
      kind: d.kind,
      model: d.model,
      sip_username: d.sip_credential && d.sip_credential.username
    }

  def render(%Tenant{} = t),
    do: %{
      id: t.id,
      name: t.name,
      slug: t.slug,
      sip_domain: t.sip_domain,
      timezone: t.timezone,
      locale: t.locale,
      plan_id: t.plan_id,
      created_at: t.inserted_at
    }

  def api_key,
    do:
      object("ApiKey", %{
        id: @id,
        name: %{type: "string"},
        prefix: %{type: "string", description: "the key's first characters"},
        scopes: %{type: "array", items: %{type: "string", enum: ApiKey.scopes()}},
        kind: %{type: "string", enum: ["tenant", "platform"]},
        tenant_id: %{type: ["string", "null"], format: "uuid"},
        expires_at: %{type: ["string", "null"], format: "date-time"},
        created_at: @time
      })

  @extension_fields %{
    number: %{type: "string", pattern: "^[1-9][0-9]{1,5}$", example: "101"},
    name: %{type: "string", maxLength: 100, example: "Dana"},
    external_caller_id: %{type: ["string", "null"], description: "E.164"},
    dnd: %{type: "boolean"},
    call_waiting: %{type: "boolean"},
    forward_always: @nullable_string,
    forward_busy: @nullable_string,
    forward_no_answer: @nullable_string,
    no_answer_seconds: %{type: "integer", minimum: 5, maximum: 120},
    follow_me_enabled: %{type: "boolean"},
    follow_me_numbers: %{type: "array", items: %{type: "string"}, maxItems: 5}
  }

  def extension_input,
    do: object("ExtensionInput", @extension_fields, required: ["number", "name"])

  def extension,
    do:
      object(
        "Extension",
        Map.merge(@extension_fields, %{
          id: @id,
          devices: %{
            type: "array",
            items:
              object("Device", %{
                id: @id,
                label: %{type: "string"},
                kind: %{type: "string"},
                model: @nullable_string,
                sip_username: @nullable_string
              })
          }
        })
      )

  def tenant,
    do:
      object("Tenant", %{
        id: @id,
        name: %{type: "string"},
        slug: %{type: "string"},
        sip_domain: %{type: "string"},
        timezone: %{type: "string"},
        locale: %{type: "string"},
        plan_id: @id,
        created_at: @time
      })

  def error,
    do:
      object(
        "Error",
        %{
          error:
            object(
              "ErrorBody",
              %{
                code: %{type: "string", example: "not_found"},
                message: %{type: "string"},
                details: %{type: "object"}
              },
              required: ["code", "message"]
            )
        },
        required: ["error"]
      )

  # A named schema: Spec moves it to components/schemas and refers to it by name.
  defp object(name, properties, opts \\ []) do
    %{"x-name": name, type: "object", properties: properties}
    |> then(&if(opts[:required], do: Map.put(&1, :required, opts[:required]), else: &1))
  end
end
