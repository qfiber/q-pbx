defmodule QPBX.Web.Api.SpecHTML do
  @moduledoc false
  use QPBX.Web, :html

  def docs(assigns) do
    ~H"""
    <main
      class="mx-auto max-w-5xl px-4 py-8"
      id="api-explorer"
      data-spec={~p"/v1/openapi.json"}
      data-label-send={gettext("Send")}
      data-label-response={gettext("Response")}
      data-label-body={gettext("Request body (JSON)")}
      data-label-idempotency={gettext("Idempotency-Key (optional)")}
      data-label-scope={gettext("Scope")}
      data-label-error={gettext("The request could not be sent.")}
      data-label-file={gettext("File")}
    >
      <h1 class="text-2xl font-semibold">{gettext("Q-PBX API explorer")}</h1>
      <p class="mt-2 text-sm opacity-80">
        {gettext(
          "Try the API with a key from the portal (API keys page). The key stays in this page and is sent only to this server."
        )}
        <a href={~p"/v1/openapi.json"} class="link" dir="ltr">openapi.json</a>
      </p>
      <label class="mt-4 block">
        <span class="text-sm font-medium">{gettext("API key")}</span>
        <input
          id="api-key"
          type="password"
          autocomplete="off"
          dir="ltr"
          class="input input-bordered mt-1 w-full"
          placeholder="qpbx_..."
        />
      </label>
      <div id="operations" class="mt-6 space-y-3" dir="ltr"></div>
    </main>
    <script defer src={~p"/assets/js/api_explorer.js"}>
    </script>
    """
  end
end
