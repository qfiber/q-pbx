defmodule QPBX.Web.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use QPBX.Web, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :locale, :string, default: "en"
  attr :current_account, :map, default: nil

  attr :idle_timeout, :integer,
    default: nil,
    doc: "seconds; shows the idle warning on signed-in pages"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8 border-b border-base-300">
      <div class="flex-1 flex items-center gap-4">
        <a href={home(@current_account)} class="shrink-0" id="home-logo" aria-label="Q-PBX">
          <QPBX.Web.Logo.logo class="h-7 w-auto" />
        </a>
        <nav :if={match?(%QPBX.Core.PlatformAdmin{}, @current_account)} class="flex gap-2">
          <.link navigate={~p"/platform"} class="btn btn-ghost btn-sm">{gettext("Tenants")}</.link>
          <.link navigate={~p"/platform/plans"} class="btn btn-ghost btn-sm">
            {gettext("Plans")}
          </.link>
          <.link navigate={~p"/platform/firewall"} class="btn btn-ghost btn-sm" id="nav-firewall">
            {gettext("Firewall")}
          </.link>
          <.link navigate={~p"/platform/trunks"} class="btn btn-ghost btn-sm" id="nav-trunks">
            {gettext("Trunks")}
          </.link>
          <.link navigate={~p"/platform/numbers"} class="btn btn-ghost btn-sm" id="nav-dids">
            {gettext("Numbers")}
          </.link>
          <.link navigate={~p"/platform/numbering"} class="btn btn-ghost btn-sm" id="nav-numbering">
            {gettext("Numbering")}
          </.link>
          <.link navigate={~p"/platform/protection"} class="btn btn-ghost btn-sm" id="nav-protection">
            {gettext("SIP protection")}
          </.link>
          <.link navigate={~p"/platform/fraud"} class="btn btn-ghost btn-sm" id="nav-fraud">
            {gettext("Fraud protection")}
          </.link>
          <.link navigate={~p"/platform/admins"} class="btn btn-ghost btn-sm" id="nav-admins">
            {gettext("Platform admins")}
          </.link>
          <.link navigate={~p"/platform/audit"} class="btn btn-ghost btn-sm" id="nav-audit">
            {gettext("Audit log")}
          </.link>
        </nav>
        <nav :if={tenant_user?(@current_account)} class="flex flex-wrap gap-2">
          <.link navigate={~p"/app/me"} class="btn btn-ghost btn-sm" id="nav-me">
            {gettext("My extension")}
          </.link>
        </nav>
        <nav :if={tenant_admin?(@current_account)} class="flex flex-wrap gap-2">
          <.link navigate={~p"/app/extensions"} class="btn btn-ghost btn-sm" id="nav-extensions">
            {gettext("Extensions")}
          </.link>
          <.link navigate={~p"/app/voicemail"} class="btn btn-ghost btn-sm" id="nav-voicemail">
            {gettext("Voicemail")}
          </.link>
          <.link navigate={~p"/app/calls"} class="btn btn-ghost btn-sm" id="nav-calls">
            {gettext("Calls")}
          </.link>
          <.link navigate={~p"/app/users"} class="btn btn-ghost btn-sm" id="nav-users">
            {gettext("Users")}
          </.link>
          <.link navigate={~p"/app/audit"} class="btn btn-ghost btn-sm" id="nav-tenant-audit">
            {gettext("Audit log")}
          </.link>
          <.link navigate={~p"/app/numbers"} class="btn btn-ghost btn-sm" id="nav-numbers">
            {gettext("Numbers")}
          </.link>
          <.link navigate={~p"/app/routes"} class="btn btn-ghost btn-sm" id="nav-routes">
            {gettext("Outbound routes")}
          </.link>
          <.link navigate={~p"/app/office-ips"} class="btn btn-ghost btn-sm" id="nav-office-ips">
            {gettext("Office IPs")}
          </.link>
          <.link navigate={~p"/app/number-format"} class="btn btn-ghost btn-sm" id="nav-number-format">
            {gettext("Number format")}
          </.link>
        </nav>
      </div>
      <div class="flex-none flex items-center gap-2">
        <.link
          :for={{name, code} <- QPBX.Web.Locale.options()}
          :if={code != @locale}
          href={~p"/locale/#{code}"}
          lang={code}
          class="btn btn-ghost btn-sm"
          id={"locale-#{code}"}
        >
          {name}
        </.link>
        <.link
          :if={@current_account}
          navigate={account_path(@current_account)}
          class="btn btn-ghost btn-sm"
          id="account"
        >
          {gettext("Sessions")}
        </.link>
        <.link
          :if={@current_account}
          href={~p"/logout"}
          method="delete"
          class="btn btn-ghost btn-sm"
          id="logout"
        >
          {gettext("Log out")}
        </.link>
        <.theme_toggle />
      </div>
    </header>

    <main class="px-4 py-12 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-5xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />

    <div
      :if={@idle_timeout}
      id="idle-warning"
      phx-hook="IdleWarning"
      data-idle-ms={@idle_timeout * 1000}
      class="toast toast-bottom toast-center hidden"
      role="alert"
    >
      <div class="alert alert-warning">
        <span>{gettext("You will be signed out soon because of inactivity.")}</span>
        <button class="btn btn-sm" data-keepalive>{gettext("Stay signed in")}</button>
      </div>
    </div>
    """
  end

  defp tenant_admin?(%QPBX.Core.User{} = user), do: QPBX.Core.User.role(user) == "tenant_admin"
  defp tenant_admin?(_), do: false

  defp tenant_user?(account), do: match?(%QPBX.Core.User{}, account)

  defp account_path(%QPBX.Core.PlatformAdmin{}), do: ~p"/platform/account"
  defp account_path(_), do: ~p"/app/account"

  defp home(%QPBX.Core.PlatformAdmin{}), do: ~p"/platform"
  defp home(%QPBX.Core.User{}), do: ~p"/app"
  defp home(_), do: ~p"/login"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
