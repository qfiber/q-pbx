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
      <.header>
        {gettext("Extension %{number}", number: @ext.number)}
        <:subtitle>{@ext.name}</:subtitle>
        <:actions>
          <.link
            navigate={~p"/app/extensions/#{@ext.id}/voicemail"}
            class="btn btn-ghost btn-sm"
            id="ext-voicemail"
          >
            {gettext("Voicemail")}
          </.link>
          <.link navigate={~p"/app/extensions"} class="btn btn-ghost btn-sm">
            {gettext("All extensions")}
          </.link>
        </:actions>
      </.header>

      <div :if={@secret} class="alert alert-warning" id="device-secret" role="alert">
        <div>
          <p class="font-semibold">{gettext("Copy this password now. It is shown only once.")}</p>
          <p>{gettext("SIP user")}: <code dir="ltr" id="secret-username">{@secret.username}</code></p>
          <p>{gettext("Password")}: <code dir="ltr" id="secret-password">{@secret.password}</code></p>
          <p>{gettext("SIP domain")}: <code dir="ltr">{@current_account.tenant.sip_domain}</code></p>
        </div>
        <button class="btn btn-sm" phx-click="hide_secret">{gettext("Done")}</button>
      </div>

      <h2 class="text-lg font-semibold">{gettext("Devices")}</h2>
      <.table id="devices" rows={@ext.devices}>
        <:col :let={d} label={gettext("Label")}>{if d.label == "", do: "—", else: d.label}</:col>
        <:col :let={d} label={gettext("SIP user")}>
          <span dir="ltr">{d.sip_credential.username}</span>
        </:col>
        <:col :let={d} label={gettext("Kind")}>{kind_label(d.kind)}</:col>
        <:col :let={d} label={gettext("MAC")}><span dir="ltr">{d.mac || "—"}</span></:col>
        <:action :let={d}>
          <.link
            phx-click="reset_device"
            phx-value-id={d.id}
            id={"reset-#{d.id}"}
            data-confirm={
              gettext("Make a new password? The device stops working until it gets the new one.")
            }
          >
            {gettext("New password")}
          </.link>
        </:action>
        <:action :let={d}>
          <.link
            phx-click="delete_device"
            phx-value-id={d.id}
            id={"delete-device-#{d.id}"}
            data-confirm={gettext("Remove device %{label}?", label: d.label)}
          >
            {gettext("Remove")}
          </.link>
        </:action>
      </.table>

      <.form
        for={@device_form}
        id="device-form"
        phx-change="validate_device"
        phx-submit="add_device"
        class="mt-4"
      >
        <div class="grid sm:grid-cols-4 gap-2">
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
        </div>
        <.button variant="primary">{gettext("Add device")}</.button>
      </.form>

      <h2 class="text-lg font-semibold mt-8">{gettext("Call features")}</h2>
      <.form for={@form} id="extension-form" phx-submit="save">
        <.input field={@form[:name]} label={gettext("Name")} required />
        <.input
          field={@form[:external_caller_id]}
          label={gettext("Outside caller ID (one of your numbers)")}
          dir="ltr"
        />
        <.input field={@form[:dnd]} type="checkbox" label={gettext("Do not disturb")} />
        <.input field={@form[:call_waiting]} type="checkbox" label={gettext("Call waiting")} />
        <.input field={@form[:forward_always]} label={gettext("Forward all calls to")} dir="ltr" />
        <.input field={@form[:forward_busy]} label={gettext("Forward when busy to")} dir="ltr" />
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
        <.input field={@form[:follow_me_enabled]} type="checkbox" label={gettext("Follow me")} />
        <.input
          name="extension[follow_me_text]"
          value={@form.params["follow_me_text"]}
          id="extension_follow_me_text"
          label={gettext("Follow-me numbers (comma-separated, up to 5)")}
          dir="ltr"
          errors={translate_list_errors(@form[:follow_me_numbers])}
        />
        <p class="text-sm opacity-70">
          {gettext("Numbers can be typed the local way, for example 02-123-4567.")}
        </p>
        <.button variant="primary">{gettext("Save")}</.button>
      </.form>

      <div class="mt-12">
        <.button
          phx-click="delete"
          id="delete-extension"
          data-confirm={
            gettext("Delete extension %{number} and all its devices?", number: @ext.number)
          }
        >
          {gettext("Delete extension")}
        </.button>
      </div>
    </Layouts.app>
    """
  end

  defp translate_list_errors(field), do: Enum.map(field.errors, &translate_error/1)

  defp kind_label("desk_phone"), do: gettext("Desk phone")
  defp kind_label("softphone"), do: gettext("Softphone")
  defp kind_label("ata"), do: gettext("Analog adapter (ATA)")
  defp kind_label("mobile"), do: gettext("Mobile app")
end
