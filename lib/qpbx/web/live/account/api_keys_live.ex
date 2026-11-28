defmodule QPBX.Web.Account.ApiKeysLive do
  @moduledoc """
  API keys of the signed-in admin's scope: a tenant admin manages the tenant's keys, a
  platform admin the platform's. A new key is shown once; revoking stops it at once.
  """
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Core.ApiKey

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("API keys"),
       new_token: nil,
       form: to_form(Core.change_api_key())
     )
     |> load()}
  end

  defp load(socket), do: assign(socket, keys: Core.list_api_keys(socket.assigns.current_scope))

  @impl true
  def handle_event("validate", %{"api_key" => params}, socket),
    do:
      {:noreply,
       assign(socket, form: to_form(Map.put(Core.change_api_key(params), :action, :validate)))}

  def handle_event("save", %{"api_key" => params}, socket) do
    %{current_scope: scope, current_account: me} = socket.assigns

    case Core.create_api_key(scope, params, me) do
      {:ok, key, token} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Key %{name} created.", name: key.name))
         |> assign(new_token: token, form: to_form(Core.change_api_key()))
         |> load()}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert)))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    %{current_scope: scope, current_account: me} = socket.assigns

    case Core.revoke_api_key(scope, id, me) do
      {:ok, key} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Key %{name} revoked.", name: key.name))
         |> assign(new_token: nil)
         |> load()}

      {:error, :not_found} ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, new_token: nil)}

  defp scope_label("read"), do: gettext("Read")
  defp scope_label("write"), do: gettext("Write")
  defp scope_label("calls"), do: gettext("Call control")
  defp scope_label("fax"), do: gettext("Fax")
  defp scope_label("admin"), do: gettext("Admin (users, keys, webhooks)")

  defp expiry_options,
    do:
      Enum.map(ApiKey.expiry_days(), &{ngettext("1 day", "%{count} days", &1), to_string(&1)}) ++
        [{gettext("Never"), "never"}]

  defp when_text(nil, none), do: none
  defp when_text(at, _), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      locale={@locale}
      current_account={@current_account}
      unread={assigns[:unread]}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("API keys")}
        <:subtitle>
          {gettext(
            "Keys let your own programs use the REST API. Each key has scopes and an expiry; revoke a key to stop it at once."
          )}
          <.link href={~p"/v1/docs"} class="link">{gettext("API explorer")}</.link>
        </:subtitle>
      </.header>

      <div
        :if={@new_token}
        id="new-token"
        class="rounded-[12px] border border-warning/50 bg-warm-pale p-4 space-y-2"
      >
        <p class="flex items-center gap-2 text-sm font-medium text-warm-ink">
          <.icon name="hero-key" class="size-5" />
          {gettext("Copy this key now. It is not shown again.")}
        </p>
        <code
          dir="ltr"
          class="block break-all select-all font-mono rounded-[8px] bg-base-100 border border-hairline p-2 text-sm"
          id="new-token-value"
        >
          {@new_token}
        </code>
        <.button phx-click="dismiss" variant="ghost">{gettext("Done")}</.button>
      </div>

      <.live_component
        module={PagedTable}
        id="api-keys"
        rows={@keys}
        search={& &1.name}
        placeholder={gettext("Search keys")}
        empty={gettext("No keys yet.")}
      >
        <:col :let={k} label={gettext("Name")}>
          <span class="font-medium">{k.name}</span>
          <code class="block text-xs text-muted" dir="ltr">{k.prefix}…</code>
        </:col>
        <:col :let={k} label={gettext("Scopes")}>
          <div class="flex flex-wrap gap-1">
            <.chip :for={sc <- k.scopes}>{scope_label(sc)}</.chip>
          </div>
        </:col>
        <:col :let={k} label={gettext("Expires")}>
          <span dir="ltr">{when_text(k.expires_at, gettext("Never"))}</span>
          <.chip :if={ApiKey.expired?(k)} tone={:danger} class="ms-1">{gettext("Expired")}</.chip>
        </:col>
        <:col :let={k} label={gettext("Last used")}>
          <span dir="ltr">{when_text(k.last_used_at, gettext("Not yet"))}</span>
        </:col>
        <:action :let={k}>
          <.link
            phx-click="revoke"
            phx-value-id={k.id}
            id={"revoke-#{k.id}"}
            class="btn btn-ghost btn-xs text-error"
            data-confirm={
              gettext("Revoke %{name}? Programs using it stop working at once.", name: k.name)
            }
          >
            <.icon name="hero-no-symbol" class="size-4" /> {gettext("Revoke")}
          </.link>
        </:action>
      </.live_component>

      <.form for={@form} id="api-key-form" phx-change="validate" phx-submit="save">
        <.section title={gettext("New key")} icon="hero-key">
          <div class="grid sm:grid-cols-2 gap-x-4">
            <.input field={@form[:name]} label={gettext("Name (what uses this key)")} required />
            <.input
              field={@form[:expires_in]}
              type="select"
              label={gettext("Expires after")}
              options={expiry_options()}
            />
          </div>
          <fieldset class="fieldset mb-2">
            <legend class="fieldset-legend">{gettext("Scopes")}</legend>
            <input type="hidden" name="api_key[scopes][]" value="" />
            <label :for={s <- ApiKey.scopes()} class="label">
              <input
                type="checkbox"
                class="checkbox checkbox-sm"
                name="api_key[scopes][]"
                value={s}
                id={"scope-#{s}"}
                checked={s in (@form[:scopes].value || [])}
              />
              {scope_label(s)}
            </label>
            <p
              :for={msg <- Enum.map(@form[:scopes].errors, &translate_error/1)}
              class="text-error text-sm"
            >
              {msg}
            </p>
          </fieldset>
        </.section>
        <.form_actions>
          <.button variant="primary">{gettext("Create key")}</.button>
        </.form_actions>
      </.form>
    </Layouts.app>
    """
  end
end
