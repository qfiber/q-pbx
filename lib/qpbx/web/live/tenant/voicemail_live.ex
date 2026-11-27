defmodule QPBX.Web.Tenant.VoicemailLive do
  @moduledoc "Tenant admin: the tenant's voicemail messages, played in the browser, kept or deleted."
  use QPBX.Web, :live_view
  alias QPBX.{Core, Telephony}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: QPBX.Events.subscribe(QPBX.Events.VoicemailChanged)
    {:ok, socket |> assign(page_title: gettext("Voicemail")) |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    numbers = Map.new(Core.list_extensions(scope), &{&1.id, &1.number})
    tz = socket.assigns.current_account.tenant.timezone

    rows =
      for {v, ext_id} <- Telephony.list_voicemails(scope),
          do: %{v: v, ext: numbers[ext_id], at: local(v.inserted_at, tz)}

    assign(socket, rows: rows)
  end

  defp local(at, tz) do
    case DateTime.shift_zone(at, tz) do
      {:ok, l} -> Calendar.strftime(l, "%Y-%m-%d %H:%M")
      _ -> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
    end
  end

  @impl true
  def handle_info({:event, %QPBX.Events.VoicemailChanged{tenant_id: tid}}, socket) do
    if tid == socket.assigns.current_scope.tenant_id,
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"id" => id}, socket) do
    Telephony.save_voicemail(socket.assigns.current_scope, id, socket.assigns.current_account)
    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Telephony.delete_voicemail(socket.assigns.current_scope, id, socket.assigns.current_account)
    {:noreply, socket |> put_flash(:info, gettext("Message deleted.")) |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      locale={@locale}
      current_account={@current_account}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("Voicemail")}
        <:subtitle>
          {gettext(
            "Messages left in the extensions' mailboxes. Playing a message here marks it as heard."
          )}
        </:subtitle>
      </.header>
      <p :if={@rows == []} id="no-voicemail">{gettext("No messages.")}</p>
      <.table :if={@rows != []} id="voicemails" rows={@rows} row_id={&"vm-#{&1.v.id}"}>
        <:col :let={r} label={gettext("Extension")}>{r.ext}</:col>
        <:col :let={r} label={gettext("From")}>
          <span dir="ltr">{r.v.caller_number || gettext("Unknown")}</span>
          <span :if={r.v.caller_name && r.v.caller_name != r.v.caller_number}>
            {"(#{r.v.caller_name})"}
          </span>
        </:col>
        <:col :let={r} label={gettext("When")}><span dir="ltr">{r.at}</span></:col>
        <:col :let={r} label={gettext("Length")}>
          {gettext("%{seconds} s", seconds: r.v.duration)}
        </:col>
        <:col :let={r} label={gettext("Status")}>
          <span class={r.v.folder == "new" && "badge badge-primary"}>
            {if r.v.folder == "new", do: gettext("New"), else: gettext("Heard")}
          </span>
        </:col>
        <:col :let={r} label={gettext("Listen")}>
          <audio
            controls
            preload="none"
            src={~p"/app/voicemail/#{r.v.id}/audio"}
            phx-hook=".MarkHeard"
            id={"audio-#{r.v.id}"}
            data-id={r.v.id}
          >
          </audio>
        </:col>
        <:action :let={r}>
          <.link
            phx-click="delete"
            phx-value-id={r.v.id}
            id={"delete-#{r.v.id}"}
            data-confirm={gettext("Delete this message?")}
          >
            {gettext("Delete")}
          </.link>
        </:action>
      </.table>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".MarkHeard">
        export default {
          mounted() {
            this.el.addEventListener("play", () => this.pushEvent("save", {id: this.el.dataset.id}), {once: true})
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
