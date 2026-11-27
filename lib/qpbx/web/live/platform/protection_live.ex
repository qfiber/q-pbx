defmodule QPBX.Web.Platform.ProtectionLive do
  @moduledoc """
  Platform admin: SIP edge protection settings (applied by Kamailio within seconds, no
  restart) and the active bans, which can be lifted.
  """
  use QPBX.Web, :live_view
  alias QPBX.Edge

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5_000, :refresh_bans)
    {:ok, socket |> assign(page_title: gettext("SIP protection")) |> load()}
  end

  defp load(socket) do
    s = Edge.get_settings()
    assign(socket, settings: s, form: to_form(Edge.change_settings(s)), bans: Edge.list_bans())
  end

  @impl true
  def handle_info(:refresh_bans, socket), do: {:noreply, assign(socket, bans: Edge.list_bans())}

  @impl true
  def handle_event("validate", %{"settings" => params}, socket),
    do:
      {:noreply,
       assign(socket,
         form:
           to_form(
             Map.put(Edge.change_settings(socket.assigns.settings, params), :action, :validate)
           )
       )}

  def handle_event("save", %{"settings" => params}, socket) do
    case Edge.update_settings(params, socket.assigns.current_account) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved. The SIP edge applies it within seconds."))
         |> load()}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :update)))}
    end
  end

  def handle_event("lift", %{"key" => key}, socket) do
    :ok = Edge.lift_ban(key, socket.assigns.current_account)

    {:noreply,
     socket |> put_flash(:info, gettext("Ban lifted.")) |> assign(bans: Edge.list_bans())}
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
        {gettext("SIP protection")}
        <:subtitle>
          {gettext(
            "The platform SIP allowlist is never limited. Tenant office IPs skip flood detection, get three times the per-phone limit and are never banned as a whole: an alert is raised instead."
          )}
        </:subtitle>
      </.header>

      <.form for={@form} id="protection-form" phx-change="validate" phx-submit="save">
        <div class="grid sm:grid-cols-2 gap-2">
          <.input
            field={@form[:flood_requests]}
            type="number"
            label={gettext("Flood: requests per address in 2 seconds")}
          />
          <.input field={@form[:ban_seconds]} type="number" label={gettext("Ban length (seconds)")} />
          <.input
            field={@form[:register_per_minute]}
            type="number"
            label={gettext("REGISTER per phone per minute")}
          />
          <.input
            field={@form[:invite_per_minute]}
            type="number"
            label={gettext("INVITE per phone per minute")}
          />
          <.input
            field={@form[:auth_failures_port]}
            type="number"
            label={gettext("Failed logins in 15 minutes to ban one phone (address and port)")}
          />
          <.input
            field={@form[:auth_failures_ip]}
            type="number"
            label={gettext("Failed logins in 15 minutes to ban the whole address")}
          />
        </div>
        <.input
          field={@form[:scanner_agents]}
          type="textarea"
          dir="ltr"
          label={gettext("Scanner user agents (names separated by |): dropped and banned")}
        />
        <.button variant="primary">{gettext("Save")}</.button>
      </.form>

      <h2 class="text-lg font-semibold mt-8">{gettext("Active bans")}</h2>
      <p class="text-sm opacity-70">
        {gettext(
          "Kept on disk: a restarted SIP edge loads them back. Whole-address bans are also in the firewall until they expire."
        )}
      </p>
      <p :if={@bans == []} id="no-bans">{gettext("No active bans.")}</p>
      <.table :if={@bans != []} id="bans" rows={@bans}>
        <:col :let={b} label={gettext("Address")}><span dir="ltr">{b.ip}</span></:col>
        <:col :let={b} label={gettext("Port")}>{b.port || gettext("all")}</:col>
        <:col :let={b} label={gettext("Reason")}>{reason_label(b.reason)}</:col>
        <:col :let={b} label={gettext("Until (UTC)")}>{b.expires_at}</:col>
        <:action :let={b}>
          <.link
            phx-click="lift"
            phx-value-key={b.key}
            id={"lift-" <> String.replace(b.key, ~r/[^A-Za-z0-9]/, "-")}
            data-confirm={gettext("Lift the ban of %{address}?", address: b.key)}
          >
            {gettext("Lift")}
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  defp reason_label("flood"), do: gettext("Flood")
  defp reason_label("scanner"), do: gettext("Scanner")
  defp reason_label("rate"), do: gettext("Rate limit")
  defp reason_label("auth failures"), do: gettext("Failed logins")
  defp reason_label(other), do: other
end
