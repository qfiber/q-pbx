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
      <.header>{gettext("My extension")}</.header>

      <p :if={!@ext} id="no-extension">
        {gettext(
          "No extension is linked to your account yet. Ask your company's admin to link one under Users."
        )}
      </p>

      <div :if={@ext}>
        <p class="text-lg" id="my-number">
          {gettext("Extension %{number}", number: @ext.number)} · {@ext.name}
        </p>

        <.form for={%{}} as={:call} id="call-form" phx-submit="call" class="mt-4 flex items-end gap-2">
          <.input name="call[to]" value="" label={gettext("Call a number")} dir="ltr" required />
          <.button variant="primary" id="call-button">{gettext("Call")}</.button>
        </.form>

        <h2 class="text-lg font-semibold mt-6">{gettext("Voicemail")}</h2>
        <p :if={@voicemails == []} id="no-voicemail">{gettext("No messages.")}</p>
        <.table :if={@voicemails != []} id="my-voicemails" rows={@voicemails} row_id={&"vm-#{&1.id}"}>
          <:col :let={v} label={gettext("From")}>
            <span dir="ltr">{v.caller_number || gettext("Unknown")}</span>
          </:col>
          <:col :let={v} label={gettext("When")}>
            <span dir="ltr">{local(v.inserted_at, @tz)}</span>
          </:col>
          <:col :let={v} label={gettext("Length")}>
            {gettext("%{seconds} s", seconds: v.duration)}
          </:col>
          <:col :let={v} label={gettext("Status")}>
            {if v.folder == "new", do: gettext("New"), else: gettext("Heard")}
          </:col>
          <:col :let={v} label={gettext("Listen")}>
            <audio
              controls
              preload="none"
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
              data-confirm={gettext("Delete this message?")}
            >
              {gettext("Delete")}
            </.link>
          </:action>
        </.table>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".MarkHeard">
          export default {
            mounted() {
              this.el.addEventListener("play", () => this.pushEvent("heard", {id: this.el.dataset.id}), {once: true})
            }
          }
        </script>

        <h2 class="text-lg font-semibold mt-6">{gettext("Recent calls")}</h2>
        <p :if={@calls == []} id="no-calls">{gettext("No calls yet.")}</p>
        <.table :if={@calls != []} id="my-calls" rows={@calls} row_id={&"cdr-#{&1.id}"}>
          <:col :let={c} label={gettext("When")}>
            <span dir="ltr">{local(c.started_at, @tz)}</span>
          </:col>
          <:col :let={c} label={gettext("From")}><span dir="ltr">{c.caller_number}</span></:col>
          <:col :let={c} label={gettext("To")}><span dir="ltr">{c.destination}</span></:col>
          <:col :let={c} label={gettext("Talk time")}>
            {div(c.billsec, 60)}:{c.billsec
            |> rem(60)
            |> Integer.to_string()
            |> String.pad_leading(2, "0")}
          </:col>
        </.table>

        <h2 class="text-lg font-semibold mt-6">{gettext("Forwarding and do not disturb")}</h2>
        <.form for={@form} id="my-extension-form" phx-submit="save">
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
          />
          <.button variant="primary">{gettext("Save")}</.button>
        </.form>

        <h2 class="text-lg font-semibold mt-6">{gettext("Devices")}</h2>
        <ul id="my-devices" class="list-disc ps-6">
          <li :for={d <- @ext.devices}>
            <span dir="ltr">{d.sip_credential.username}</span> · {d.label}
          </li>
        </ul>
        <p class="text-sm opacity-70">
          {gettext("Your admin adds devices and gives out their passwords.")}
        </p>
      </div>
    </Layouts.app>
    """
  end
end
