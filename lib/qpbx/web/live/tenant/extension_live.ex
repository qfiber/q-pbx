defmodule QPBX.Web.Tenant.ExtensionLive do
  @moduledoc """
  Tenant admin: one extension's call features and its devices. A new device's SIP password is
  shown once, right after it is created or reset, and never again.
  """
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Web.NumberInput

  @number_fields ~w(external_caller_id forward_always forward_busy forward_no_answer follow_me_numbers)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    ext = Core.get_extension!(socket.assigns.current_scope, id)

    {:ok,
     socket
     |> assign(
       page_title: gettext("Extension %{number}", number: ext.number),
       ext: ext,
       secret: nil
     )
     |> assign(
       form: ext_form(Core.change_extension(ext)),
       device_form: to_form(Core.change_device(%{"kind" => "desk_phone"}))
     )}
  end

  defp ext_form(cs) do
    follow = cs |> Ecto.Changeset.get_field(:follow_me_numbers) |> Enum.join(", ")

    to_form(cs, as: :extension)
    |> Map.update!(:params, &Map.put_new(&1, "follow_me_text", follow))
  end

  @impl true
  def handle_event("save", %{"extension" => params}, socket) do
    %{current_scope: scope, current_account: actor, ext: ext} = socket.assigns

    params =
      params
      |> Map.put("follow_me_numbers", NumberInput.split(params["follow_me_text"]))
      |> NumberInput.normalize(scope, @number_fields)

    case Core.update_extension(scope, ext, params, actor) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> reload()}
      {:error, cs} -> {:noreply, assign(socket, form: ext_form(Map.put(cs, :action, :update)))}
    end
  end

  def handle_event("add_device", %{"device" => params}, socket) do
    %{current_scope: scope, current_account: actor, ext: ext} = socket.assigns

    case Core.add_device(scope, ext, params, actor) do
      {:ok, device, password} ->
        {:noreply,
         socket
         |> assign(secret: %{username: device.sip_credential.username, password: password})
         |> assign(device_form: to_form(Core.change_device(%{"kind" => "desk_phone"})))
         |> reload()}

      {:error, cs} ->
        {:noreply, assign(socket, device_form: to_form(Map.put(cs, :action, :insert)))}
    end
  end

  def handle_event("reset_device", %{"id" => id}, socket) do
    %{current_scope: scope, current_account: actor} = socket.assigns
    {:ok, _device, password} = Core.reset_device_password(scope, id, actor)
    device = Enum.find(socket.assigns.ext.devices, &(&1.id == id))

    {:noreply,
     socket
     |> assign(secret: %{username: device.sip_credential.username, password: password})
     |> reload()}
  end

  def handle_event("delete_device", %{"id" => id}, socket) do
    {:ok, _} =
      Core.delete_device(socket.assigns.current_scope, id, socket.assigns.current_account)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Device removed. Its SIP login no longer works."))
     |> assign(secret: nil)
     |> reload()}
  end

  # Tracking typed values on the server is what lets the form clear after an add.
  def handle_event("validate_device", %{"device" => params}, socket),
    do: {:noreply, assign(socket, device_form: to_form(Core.change_device(params)))}

  def handle_event("hide_secret", _, socket), do: {:noreply, assign(socket, secret: nil)}

  def handle_event("delete", _, socket) do
    # Its voicemail first: messages and greetings are files the database cascade cannot remove.
    :ok =
      QPBX.Telephony.delete_mailbox(
        socket.assigns.current_scope,
        socket.assigns.ext.id,
        socket.assigns.current_account
      )

    {:ok, ext} =
      Core.delete_extension(
        socket.assigns.current_scope,
        socket.assigns.ext,
        socket.assigns.current_account
      )

    {:noreply,
     socket
     |> put_flash(:info, gettext("Extension %{number} deleted.", number: ext.number))
     |> push_navigate(to: ~p"/app/extensions")}
  end

  defp reload(socket) do
    ext = Core.get_extension!(socket.assigns.current_scope, socket.assigns.ext.id)
    assign(socket, ext: ext, form: ext_form(Core.change_extension(ext)))
  end

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
      <header class="flex flex-wrap items-center justify-between gap-3 pb-2">
        <div class="flex items-center gap-3 min-w-0">
          <span class="size-12 shrink-0 rounded-[12px] bg-accent-pale text-secondary grid place-items-center text-lg font-semibold tabular-nums">
            {@ext.number}
          </span>
          <div class="min-w-0">
            <h1 class="text-2xl font-semibold leading-tight tracking-tight truncate">{@ext.name}</h1>
            <p class="mt-1 text-sm text-muted">
              {gettext("Extension %{number}", number: @ext.number)} · {ngettext(
                "1 device",
                "%{count} devices",
                length(@ext.devices)
              )}
            </p>
          </div>
        </div>
        <div class="flex gap-2">
          <.link
            navigate={~p"/app/extensions/#{@ext.id}/voicemail"}
            class="btn btn-ghost btn-sm"
            id="ext-voicemail"
          >
            <.icon name="hero-inbox" class="size-4" /> {gettext("Voicemail")}
          </.link>
          <.link navigate={~p"/app/extensions"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4 rtl:rotate-180" />
            {gettext("All extensions")}
          </.link>
        </div>
      </header>

      <div
        :if={@secret}
        class="rounded-[12px] border border-warning/50 bg-warm-pale p-4 space-y-2"
        id="device-secret"
        role="alert"
      >
        <p class="font-semibold text-warm-ink">
          {gettext("Copy this password now. It is shown only once.")}
        </p>
        <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
          <dt class="text-muted">{gettext("SIP user")}</dt>
          <dd><code dir="ltr" id="secret-username" class="select-all">{@secret.username}</code></dd>
          <dt class="text-muted">{gettext("Password")}</dt>
          <dd><code dir="ltr" id="secret-password" class="select-all">{@secret.password}</code></dd>
          <dt class="text-muted">{gettext("SIP domain")}</dt>
          <dd><code dir="ltr" class="select-all">{@current_account.tenant.sip_domain}</code></dd>
        </dl>
        <button class="btn btn-sm" phx-click="hide_secret">{gettext("Done")}</button>
      </div>

      <.section
        title={gettext("Devices")}
        icon="hero-device-phone-mobile"
        hint={gettext("Each device has its own SIP login; all of them ring together.")}
      >
        <div class="space-y-4">
          <.live_component
            module={PagedTable}
            id="devices"
            rows={@ext.devices}
            empty={gettext("No devices yet. Add one below.")}
          >
            <:col :let={d} label={gettext("Device")}>
              <span class="font-medium">{if d.label == "", do: "—", else: d.label}</span>
              <span class="block text-xs text-muted" dir="ltr">{d.sip_credential.username}</span>
            </:col>
            <:col :let={d} label={gettext("Kind")}>
              <.chip tone={:plain}>{kind_label(d.kind)}</.chip>
            </:col>
            <:col :let={d} label={gettext("MAC")}>
              <span class="text-sm" dir="ltr">{d.mac || "—"}</span>
            </:col>
            <:action :let={d}>
              <.link
                phx-click="reset_device"
                phx-value-id={d.id}
                id={"reset-#{d.id}"}
                class="btn btn-ghost btn-xs"
                data-confirm={
                  gettext("Make a new password? The device stops working until it gets the new one.")
                }
              >
                <.icon name="hero-key" class="size-4" /> {gettext("New password")}
              </.link>
            </:action>
            <:action :let={d}>
              <.link
                phx-click="delete_device"
                phx-value-id={d.id}
                id={"delete-device-#{d.id}"}
                class="btn btn-ghost btn-xs text-error"
                data-confirm={gettext("Remove device %{label}?", label: d.label)}
              >
                <.icon name="hero-trash" class="size-4" /> {gettext("Remove")}
              </.link>
            </:action>
          </.live_component>

          <.form
            for={@device_form}
            id="device-form"
            phx-change="validate_device"
            phx-submit="add_device"
          >
            <div class="grid sm:grid-cols-2 lg:grid-cols-[2fr_1fr_1fr_1fr_auto] gap-x-4 items-end">
              <.input
                field={@device_form[:label]}
                label={gettext("Label (e.g. desk; empty: login is the extension number)")}
                dir="ltr"
              />
              <.input
                field={@device_form[:kind]}
                type="select"
                label={gettext("Kind")}
                options={Enum.map(Core.Device.kinds(), &{kind_label(&1), &1})}
              />
              <.input field={@device_form[:mac]} label={gettext("MAC (optional)")} dir="ltr" />
              <.input field={@device_form[:model]} label={gettext("Model (optional)")} />
              <.button variant="primary" class="mb-2">
                <.icon name="hero-plus" class="size-4" /> {gettext("Add device")}
              </.button>
            </div>
          </.form>
        </div>
      </.section>

      <.form for={@form} id="extension-form" phx-submit="save">
        <div class="divide-y divide-base-300">
          <.section title={gettext("Call features")} icon="hero-phone">
            <div class="grid sm:grid-cols-2 gap-x-4">
              <.input field={@form[:name]} label={gettext("Name")} required />
              <.input
                field={@form[:external_caller_id]}
                label={gettext("Outside caller ID (one of your numbers)")}
                dir="ltr"
              />
            </div>
            <div class="flex flex-wrap gap-x-8">
              <.input field={@form[:dnd]} type="checkbox" label={gettext("Do not disturb")} />
              <.input field={@form[:call_waiting]} type="checkbox" label={gettext("Call waiting")} />
            </div>
          </.section>
          <.section
            title={gettext("Forwarding")}
            icon="hero-arrow-uturn-right"
            hint={gettext("Numbers can be typed the local way, for example 02-123-4567.")}
          >
            <div class="grid sm:grid-cols-2 gap-x-4">
              <.input
                field={@form[:forward_always]}
                label={gettext("Forward all calls to")}
                dir="ltr"
              />
              <.input
                field={@form[:forward_busy]}
                label={gettext("Forward when busy to")}
                dir="ltr"
              />
              <.input
                field={@form[:forward_no_answer]}
                label={gettext("Forward when not answered to")}
                dir="ltr"
              />
              <.input
                field={@form[:no_answer_seconds]}
                type="number"
                label={gettext("Ring for (seconds)")}
                min="5"
                max="120"
              />
            </div>
          </.section>
          <.section
            title={gettext("Follow me")}
            icon="hero-arrows-pointing-out"
            hint={gettext("When the extension is not answered, these numbers ring together.")}
          >
            <.input
              field={@form[:follow_me_enabled]}
              type="checkbox"
              label={gettext("Follow me")}
            />
            <.input
              name="extension[follow_me_text]"
              value={@form.params["follow_me_text"]}
              id="extension_follow_me_text"
              label={gettext("Follow-me numbers (comma-separated, up to 5)")}
              dir="ltr"
              errors={translate_list_errors(@form[:follow_me_numbers])}
            />
          </.section>
        </div>
        <.form_actions>
          <.button variant="primary">{gettext("Save")}</.button>
          <.button
            type="button"
            phx-click="delete"
            id="delete-extension"
            class="btn btn-ghost text-error ms-auto"
            data-confirm={
              gettext("Delete extension %{number} and all its devices?", number: @ext.number)
            }
          >
            <.icon name="hero-trash" class="size-4" /> {gettext("Delete extension")}
          </.button>
        </.form_actions>
      </.form>
    </Layouts.app>
    """
  end

  defp translate_list_errors(field), do: Enum.map(field.errors, &translate_error/1)

  defp kind_label("desk_phone"), do: gettext("Desk phone")
  defp kind_label("softphone"), do: gettext("Softphone")
  defp kind_label("ata"), do: gettext("Analog adapter (ATA)")
  defp kind_label("mobile"), do: gettext("Mobile app")
end
