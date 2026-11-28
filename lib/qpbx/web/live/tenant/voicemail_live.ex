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
      unread={assigns[:unread]}
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
      <.live_component
        module={PagedTable}
        id="voicemails"
        rows={@rows}
        row_id={&"vm-#{&1.v.id}"}
        search={&"#{&1.ext} #{&1.v.caller_number} #{&1.v.caller_name}"}
        placeholder={gettext("Search by extension or caller")}
        empty={gettext("No messages.")}
      >
        <:col :let={r} label={gettext("Extension")}><span class="font-medium">{r.ext}</span></:col>
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
          <.chip :if={r.v.folder == "new"} tone={:warm}>{gettext("New")}</.chip>
          <.chip :if={r.v.folder != "new"} tone={:plain}>{gettext("Heard")}</.chip>
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
            class="btn btn-ghost btn-xs text-error"
            data-confirm={gettext("Delete this message?")}
          >
            <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
          </.link>
        </:action>
      </.live_component>
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
