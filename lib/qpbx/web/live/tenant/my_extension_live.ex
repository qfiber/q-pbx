defmodule QPBX.Web.Tenant.MyExtensionLive do
  @moduledoc """
  Any tenant user: their own extension (linked by a tenant admin): forwarding, do not disturb,
  follow-me; its devices; its voicemail (played here, which marks it heard) and its calls.
  """
  use QPBX.Web, :live_view
  alias QPBX.{Core, Telephony}
  alias QPBX.Web.NumberInput

  @number_fields ~w(forward_always forward_busy forward_no_answer follow_me_numbers)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: QPBX.Events.subscribe(QPBX.Events.VoicemailChanged)
    {:ok, socket |> assign(page_title: gettext("My extension")) |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    case Core.my_extension(scope) do
      nil ->
        assign(socket, ext: nil)

      ext ->
        tz = socket.assigns.current_account.tenant.timezone

        assign(socket,
          ext: ext,
          form: ext_form(Core.change_extension(ext)),
          voicemails: for({v, _} <- Telephony.list_voicemails(scope, ext.id), do: v),
          calls: Telephony.search_cdrs(scope, %{"extension" => ext.number}, tz, limit: 20),
          tz: tz
        )
    end
  end

  defp ext_form(cs) do
    follow = cs |> Ecto.Changeset.get_field(:follow_me_numbers) |> Enum.join(", ")

    cs
    |> to_form(as: :extension)
    |> Map.update!(:params, &Map.put_new(&1, "follow_me_text", follow))
  end

  @impl true
  def handle_info({:event, %QPBX.Events.VoicemailChanged{extension_id: id}}, socket) do
    if socket.assigns[:ext] && socket.assigns.ext.id == id,
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  @impl true
  # Click-to-call: the user's own phones ring, then the number is dialled from the extension.
  def handle_event("call", %{"call" => %{"to" => to}}, socket) do
    %{current_scope: scope, current_account: me, ext: ext} = socket.assigns
    to = NumberInput.normalize(%{"to" => to}, scope, ["to"])["to"]

    case Telephony.originate(scope, ext.id, to, me) do
      {:ok, _} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Your phone is ringing: answer it to call %{number}.", number: to)
         )}

      {:error, :no_devices} ->
        {:noreply, put_flash(socket, :error, gettext("Your extension has no phone to ring."))}

      {:error, :bad_target} ->
        {:noreply, put_flash(socket, :error, gettext("That is not a number Q-PBX can call."))}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("The call could not be started. Try again."))}
    end
  end

  def handle_event("save", %{"extension" => params}, socket) do
    %{current_scope: scope, current_account: actor} = socket.assigns

    params =
      params
      |> Map.put("follow_me_numbers", NumberInput.split(params["follow_me_text"]))
      |> NumberInput.normalize(scope, @number_fields)

    case Core.update_my_extension(scope, params, actor) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: ext_form(Map.put(cs, :action, :update)))}

      {:error, _} ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("heard", %{"id" => id}, socket) do
    Telephony.save_voicemail(
      socket.assigns.current_scope,
      id,
      socket.assigns.current_account,
      socket.assigns.ext.id
    )

    {:noreply, load(socket)}
  end

  def handle_event("delete_voicemail", %{"id" => id}, socket) do
    Telephony.delete_voicemail(
      socket.assigns.current_scope,
      id,
      socket.assigns.current_account,
      socket.assigns.ext.id
    )

    {:noreply, socket |> put_flash(:info, gettext("Message deleted.")) |> load()}
  end

  defp local(at, tz) do
    case DateTime.shift_zone(at, tz) do
      {:ok, l} -> Calendar.strftime(l, "%Y-%m-%d %H:%M")
      _ -> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
    end
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
      <.header :if={!@ext}>{gettext("My extension")}</.header>

      <div
        :if={!@ext}
        id="no-extension"
        class="rounded-[12px] border border-dashed border-hairline bg-base-100/60 px-6 py-10 text-center text-sm text-muted"
      >
        <.icon name="hero-phone" class="size-6 mx-auto mb-2 opacity-60" />
        {gettext(
          "No extension is linked to your account yet. Ask your company's admin to link one under Users."
        )}
      </div>

      <div :if={@ext} class="space-y-6">
        <header class="flex items-center gap-3">
          <span class="size-12 shrink-0 rounded-[12px] bg-accent-pale text-secondary grid place-items-center text-lg font-semibold tabular-nums">
            {@ext.number}
          </span>
          <div>
            <h1 class="text-2xl font-semibold leading-tight tracking-tight">
              {gettext("My extension")}
            </h1>
            <p class="mt-1 text-sm text-muted" id="my-number">
              {gettext("Extension %{number}", number: @ext.number)} · {@ext.name}
            </p>
          </div>
        </header>

        <.form for={%{}} as={:call} id="call-form" phx-submit="call">
          <div class="flex flex-wrap items-end gap-3">
            <div class="grow min-w-48">
              <.input
                name="call[to]"
                value=""
                label={gettext("Call a number")}
                dir="ltr"
                placeholder="050-123-4567"
                required
              />
            </div>
            <.button variant="primary" id="call-button" class="mb-2">
              <.icon name="hero-phone-arrow-up-right" class="size-4" /> {gettext("Call")}
            </.button>
          </div>
          <p class="text-xs text-muted">
            {gettext("Your phone rings first; answer it and the number is dialled.")}
          </p>
        </.form>

        <div class="grid xl:grid-cols-2 gap-6">
          <.section title={gettext("Voicemail")} icon="hero-inbox">
            <.live_component
              module={PagedTable}
              id="my-voicemails"
              rows={@voicemails}
              row_id={&"vm-#{&1.id}"}
              empty={gettext("No messages.")}
            >
              <:col :let={v} label={gettext("From")}>
                <span class="font-medium" dir="ltr">{v.caller_number || gettext("Unknown")}</span>
                <span class="block text-xs text-muted" dir="ltr">
                  {local(v.inserted_at, @tz)} · {gettext("%{seconds} s", seconds: v.duration)}
                </span>
              </:col>
              <:col :let={v} label={gettext("Status")}>
                <.chip :if={v.folder == "new"} tone={:warm}>{gettext("New")}</.chip>
                <.chip :if={v.folder != "new"} tone={:plain}>{gettext("Heard")}</.chip>
              </:col>
              <:col :let={v} label={gettext("Listen")}>
                <audio
                  controls
                  preload="none"
                  class="h-8 max-w-48"
                  src={~p"/app/voicemail/#{v.id}/audio"}
                  phx-hook=".MarkHeard"
                  id={"audio-#{v.id}"}
                  data-id={v.id}
                >
                </audio>
              </:col>
              <:action :let={v}>
                <.link
                  phx-click="delete_voicemail"
                  phx-value-id={v.id}
                  id={"delete-#{v.id}"}
                  class="btn btn-ghost btn-xs text-error"
                  title={gettext("Delete")}
                  data-confirm={gettext("Delete this message?")}
                >
                  <.icon name="hero-trash" class="size-4" />
                  <span class="sr-only">{gettext("Delete")}</span>
                </.link>
              </:action>
            </.live_component>
          </.section>

          <.section title={gettext("Recent calls")} icon="hero-clock">
            <.live_component
              module={PagedTable}
              id="my-calls"
              rows={@calls}
              row_id={&"cdr-#{&1.id}"}
              empty={gettext("No calls yet.")}
            >
              <:col :let={c} label={gettext("Call")}>
                <span class="text-sm" dir="ltr">{c.caller_number} → {c.destination}</span>
                <span class="block text-xs text-muted" dir="ltr">{local(c.started_at, @tz)}</span>
              </:col>
              <:col :let={c} label={gettext("Talk time")}>
                <span class="tabular-nums">
                  {div(c.billsec, 60)}:{c.billsec
                  |> rem(60)
                  |> Integer.to_string()
                  |> String.pad_leading(2, "0")}
                </span>
              </:col>
            </.live_component>
          </.section>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".MarkHeard">
          export default {
            mounted() {
              this.el.addEventListener("play", () => this.pushEvent("heard", {id: this.el.dataset.id}), {once: true})
            }
          }
        </script>

        <.form for={@form} id="my-extension-form" phx-submit="save">
          <div class="divide-y divide-base-300">
            <.section title={gettext("Availability")} icon="hero-bell-slash">
              <div class="flex flex-wrap gap-x-8">
                <.input field={@form[:dnd]} type="checkbox" label={gettext("Do not disturb")} />
                <.input
                  field={@form[:call_waiting]}
                  type="checkbox"
                  label={gettext("Call waiting")}
                />
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
              />
            </.section>
          </div>
          <.form_actions><.button variant="primary">{gettext("Save")}</.button></.form_actions>
        </.form>

        <.section
          title={gettext("Devices")}
          icon="hero-device-phone-mobile"
          hint={gettext("Your admin adds devices and gives out their passwords.")}
        >
          <ul id="my-devices" class="grid sm:grid-cols-2 lg:grid-cols-3 gap-3">
            <li
              :for={d <- @ext.devices}
              class="rounded-[12px] border border-hairline bg-base-100 shadow-card p-4 flex items-center gap-3"
            >
              <.icon name="hero-device-phone-mobile" class="size-5 text-secondary" />
              <div class="min-w-0">
                <span class="block font-medium truncate">
                  {if d.label == "", do: "—", else: d.label}
                </span>
                <span class="block text-xs text-muted" dir="ltr">{d.sip_credential.username}</span>
              </div>
            </li>
          </ul>
        </.section>
      </div>
    </Layouts.app>
    """
  end
end
