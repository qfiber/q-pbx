defmodule QPBX.Web.Api.Spec do
  @moduledoc """
  The OpenAPI 3.1 document, built from the router's `/v1` routes and each controller's
  `operation/1` (the same descriptions `QPBX.Web.Api.Authorize` enforces). A `/v1` route
  whose controller does not describe its action fails `document/0`, and the tests with it.
  """
  alias QPBX.Web.Api.Schemas

  def document do
    {paths, schemas} =
      QPBX.Web.Router
      |> Phoenix.Router.routes()
      |> Enum.filter(
        &(String.starts_with?(&1.path, "/v1/") and &1.plug != QPBX.Web.Api.SpecController)
      )
      |> Enum.reduce({%{}, %{}}, &add_route/2)

    {error, schemas} = extract(Schemas.error(), schemas)

    %{
      openapi: "3.1.0",
      info: %{
        title: "Q-PBX API",
        version: "1",
        description:
          "Send an API key as `Authorization: Bearer qpbx_...`. Tenant keys act in their " <>
            "tenant; platform keys manage the platform. Each operation names the scope it " <>
            "needs. Lists are paged with `limit` and `cursor` (`next_cursor` is null on the " <>
            "last page). A POST with an `Idempotency-Key` header runs once; retries within " <>
            "24 hours get the first response. Errors look like " <>
            "`{\"error\": {\"code\": ..., \"message\": ...}}`."
      },
      servers: [%{url: "/"}],
      paths: paths,
      components: %{
        schemas: Map.put(schemas, "Error", error),
        securitySchemes: %{apiKey: %{type: "http", scheme: "bearer"}}
      },
      security: [%{apiKey: []}]
    }
  end

  defp add_route(%{path: path, verb: verb, plug: controller, plug_opts: action}, {paths, schemas}) do
    op = controller.operation(action)
    {response, schemas} = extract(wrap(op.response), schemas)
    {body, schemas} = if op[:body], do: extract(op.body, schemas), else: {nil, schemas}
    status = to_string(op[:status] || 200)

    operation =
      %{
        operationId: "#{op.tag |> String.downcase() |> String.replace(" ", "_")}.#{action}",
        summary: op.summary,
        tags: [op.tag],
        description: "Scope: `#{op.scope}`. Key: #{audience(op.audience)}.",
        "x-scope": op.scope,
        parameters: path_params(path) ++ (op[:params] || []),
        responses: %{
          status => json("OK", response),
          "4XX" => json("Error", %{"$ref": "#/components/schemas/Error"})
        }
      }
      |> then(
        &if(body,
          do: Map.put(&1, :requestBody, Map.put(json("", body), :required, true)),
          else: &1
        )
      )
      |> then(
        &if(verb == :post,
          do: Map.update!(&1, :parameters, fn ps -> ps ++ [idempotency()] end),
          else: &1
        )
      )

    {put_in(paths, [Access.key(oa_path(path), %{}), verb], operation), schemas}
  end

  defp wrap({:list, schema}),
    do: %{
      type: "object",
      properties: %{
        data: %{type: "array", items: schema},
        next_cursor: %{type: ["string", "null"]}
      },
      required: ["data", "next_cursor"]
    }

  defp wrap(schema), do: %{type: "object", properties: %{data: schema}, required: ["data"]}

  defp json(description, schema),
    do: %{description: description, content: %{"application/json" => %{schema: schema}}}

  defp idempotency,
    do: %{
      name: "Idempotency-Key",
      in: "header",
      description: "Any unique string (up to 255 characters); retries with it run once",
      schema: %{type: "string", maxLength: 255}
    }

  defp audience(:any), do: "tenant or platform"
  defp audience(:tenant), do: "tenant"
  defp audience(:platform), do: "platform"

  defp path_params(path) do
    for ":" <> name <- String.split(path, "/"),
        do: %{name: name, in: "path", required: true, schema: %{type: "string"}}
  end

  defp oa_path(path), do: Regex.replace(~r/:(\w+)/, path, "{\\1}")

  # Named schemas go to components/schemas; the tree refers to them by name.
  defp extract(%{"x-name": name} = schema, schemas) do
    {inner, schemas} = schema |> Map.delete(:"x-name") |> extract(schemas)
    {%{"$ref": "#/components/schemas/#{name}"}, Map.put(schemas, name, inner)}
  end

  defp extract(map, schemas) when is_map(map) do
    Enum.reduce(map, {%{}, schemas}, fn {k, v}, {acc, schemas} ->
      {v, schemas} = extract(v, schemas)
      {Map.put(acc, k, v), schemas}
    end)
  end

  defp extract(list, schemas) when is_list(list) do
    {items, schemas} = Enum.map_reduce(list, schemas, &extract/2)
    {items, schemas}
  end

  defp extract(other, schemas), do: {other, schemas}
end
