// The API explorer at /v1/docs: lists the operations of /v1/openapi.json and sends requests
// with the key typed into the page. Built with DOM calls only (no innerHTML), so nothing from
// the document or a response is ever run as markup.
const root = document.getElementById("api-explorer")
const label = (name) => root.dataset["label" + name]

const el = (tag, attrs = {}, children = []) => {
  const node = document.createElement(tag)
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "text") node.textContent = v
    else node.setAttribute(k, v)
  }
  for (const child of children) node.append(child)
  return node
}

const resolve = (spec, schema) =>
  schema && schema.$ref ? spec.components.schemas[schema.$ref.split("/").pop()] : schema

// A starting body from the request schema's examples (or empty values).
const example = (spec, schema) => {
  schema = resolve(spec, schema)
  const body = {}
  for (const name of schema.required || Object.keys(schema.properties || {})) {
    const prop = schema.properties[name] || {}
    body[name] = prop.example ?? (prop.type === "boolean" ? false : prop.type === "integer" ? 0 : "")
  }
  return JSON.stringify(body, null, 2)
}

const operation = (spec, path, method, op) => {
  const inputs = {}
  const params = (op.parameters || []).filter((p) => p.in !== "header")
  const fields = params.map((p) => {
    const input = el("input", {class: "input input-bordered input-sm w-full", placeholder: p.name})
    inputs[p.name] = {param: p, input}
    return el("label", {class: "block"}, [el("span", {class: "text-xs", text: `${p.name} (${p.in})`}), input])
  })

  let body = null
  const jsonBody = op.requestBody && op.requestBody.content["application/json"]
  if (jsonBody) {
    const schema = jsonBody.schema
    body = el("textarea", {class: "textarea textarea-bordered w-full font-mono text-xs", rows: "8"})
    body.value = example(spec, schema)
    fields.push(el("label", {class: "block"}, [el("span", {class: "text-xs", text: label("Body")}), body]))
  }

  let idem = null
  if (method === "post") {
    idem = el("input", {class: "input input-bordered input-sm w-full"})
    fields.push(el("label", {class: "block"}, [el("span", {class: "text-xs", text: label("Idempotency")}), idem]))
  }

  const output = el("pre", {class: "mt-2 max-h-96 overflow-auto rounded bg-base-200 p-2 text-xs"})
  const send = el("button", {type: "button", class: "btn btn-primary btn-sm mt-2", text: label("Send")})

  send.addEventListener("click", async () => {
    let url = path
    const query = new URLSearchParams()
    for (const {param, input} of Object.values(inputs)) {
      if (param.in === "path") url = url.replace(`{${param.name}}`, encodeURIComponent(input.value))
      else if (input.value !== "") query.set(param.name, input.value)
    }
    if ([...query].length) url += "?" + query

    const headers = {authorization: "Bearer " + document.getElementById("api-key").value.trim()}
    if (body) headers["content-type"] = "application/json"
    if (idem && idem.value) headers["idempotency-key"] = idem.value

    try {
      const res = await fetch(url, {method: method.toUpperCase(), headers, body: body ? body.value : undefined})
      const text = await res.text()
      let shown = text
      try { shown = JSON.stringify(JSON.parse(text), null, 2) } catch (_) {}
      output.textContent = `${res.status} ${res.statusText}\n\n${shown}`
    } catch (e) {
      output.textContent = label("Error") + " " + e
    }
  })

  return el("details", {class: "rounded border border-base-300 p-3"}, [
    el("summary", {class: "cursor-pointer"}, [
      el("span", {class: "badge badge-outline me-2 font-mono", text: method.toUpperCase()}),
      el("span", {class: "font-mono", text: path}),
      el("span", {class: "ms-2 opacity-70", text: `${op.summary} · ${label("Scope")}: ${op["x-scope"]}`}),
    ]),
    el("div", {class: "mt-3 space-y-2"}, [...fields, send, el("p", {class: "text-xs mt-2", text: label("Response")}), output]),
  ])
}

fetch(root.dataset.spec)
  .then((res) => res.json())
  .then((spec) => {
    const list = document.getElementById("operations")
    for (const [path, methods] of Object.entries(spec.paths)) {
      for (const [method, op] of Object.entries(methods)) list.append(operation(spec, path, method, op))
    }
  })
