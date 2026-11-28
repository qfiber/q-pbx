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

  attr :unread, :integer, default: nil, doc: "unread notifications (the bell); nil: no bell"

  attr :idle_timeout, :integer,
    default: nil,
    doc: "seconds; shows the idle warning on signed-in pages"

  slot :inner_block, required: true

  def app(%{current_account: nil} = assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <header class="flex items-center gap-2 h-14 px-4 sm:px-6 bg-base-100 border-b border-hairline">
        <a href={~p"/login"} id="home-logo" aria-label="Q-PBX" class="shrink-0">
          <QPBX.Web.Logo.logo class="h-6 w-auto" />
        </a>
        <div class="flex-1" />
        <.top_tools locale={@locale} />
      </header>
      <main class="px-4 py-10 sm:px-6">
        <div class="mx-auto max-w-3xl space-y-4">{render_slot(@inner_block)}</div>
      </main>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  def app(assigns) do
    assigns = assign(assigns, :groups, nav_groups(assigns.current_account))

    ~H"""
    <div class="min-h-screen bg-base-200">
      <%!-- The menu: fixed on the reading-start side; on a phone it slides in (the checkbox). --%>
      <input id="nav-drawer" type="checkbox" class="peer sr-only" />
      <label
        for="nav-drawer"
        class="fixed inset-0 z-30 bg-black/40 hidden peer-checked:block lg:hidden"
        aria-label={gettext("Close the menu")}
      >
      </label>
      <aside class={[
        "on-night fixed inset-y-0 start-0 z-40 flex flex-col w-72 bg-gradient-to-b from-night to-night-2 text-on-night",
        "transition-transform -translate-x-full rtl:translate-x-full peer-checked:translate-x-0! lg:translate-x-0!"
      ]}>
        <.sidebar groups={@groups} current_account={@current_account} />
      </aside>
      <div class="lg:ps-72 flex flex-col min-h-screen min-w-0">
        <header class="sticky top-0 z-20 flex items-center gap-2 h-14 px-4 sm:px-6 lg:px-10 bg-base-100/90 backdrop-blur border-b border-hairline">
          <label
            for="nav-drawer"
            id="menu-button"
            class="btn btn-ghost btn-sm btn-square lg:hidden"
            aria-label={gettext("Menu")}
          >
            <.icon name="hero-bars-3" class="size-5" />
          </label>
          <a href={home(@current_account)} class="lg:hidden shrink-0" aria-label="Q-PBX">
            <QPBX.Web.Logo.logo class="h-6 w-auto" />
          </a>
          <div class="flex-1" />
          <.link
            :if={@unread}
            navigate={notifications_path(@current_account)}
            class="btn btn-ghost btn-sm btn-square indicator"
            id="bell"
            aria-label={gettext("Notifications")}
          >
            <.icon name="hero-bell" class="size-5" />
            <span
              :if={@unread > 0}
              class="indicator-item badge badge-accent badge-xs font-semibold"
              id="bell-count"
            >
              {@unread}
            </span>
          </.link>
          <.top_tools locale={@locale} />
        </header>

        <main class="flex-1 px-4 py-6 sm:px-6 lg:px-10 lg:py-8">
          <div class="page mx-auto max-w-6xl space-y-6">{render_slot(@inner_block)}</div>
        </main>
      </div>
    </div>

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

  attr :groups, :list, required: true
  attr :current_account, :map, required: true

  defp sidebar(assigns) do
    ~H"""
    <a
      href={home(@current_account)}
      class="block px-6 pt-6 pb-5"
      id="home-logo"
      aria-label="Q-PBX"
    >
      <QPBX.Web.Logo.logo class="h-8 w-auto" />
    </a>
    <nav
      id="side-nav"
      class="flex-1 overflow-y-auto px-3 pb-6 space-y-5"
      aria-label={gettext("Main")}
    >
      <div :for={{title, links} <- @groups}>
        <p class="px-3 mb-1.5 text-[0.7rem] font-semibold uppercase tracking-wider text-on-night-muted/70">
          {title}
        </p>
        <.link
          :for={{label, path, id, icon} <- links}
          navigate={path}
          id={id}
          class="side-link"
          data-exact={path in [~p"/app", ~p"/platform"]}
        >
          <.icon name={icon} class="side-icon" />
          <span>{label}</span>
        </.link>
      </div>
    </nav>
    <div class="border-t border-white/10 p-3 space-y-1">
      <div class="flex items-center gap-3 px-3 py-2">
        <div class="size-9 shrink-0 rounded-full bg-accent-bright/20 text-accent-bright grid place-items-center font-semibold">
          {initial(@current_account)}
        </div>
        <div class="min-w-0">
          <p class="text-sm font-semibold truncate">{@current_account.name}</p>
          <p class="text-xs text-on-night-muted truncate" dir="ltr">{@current_account.email}</p>
        </div>
      </div>
      <.link navigate={account_path(@current_account)} class="side-link" id="account">
        <.icon name="hero-lock-closed" class="side-icon" />
        <span>{gettext("Sign-in and sessions")}</span>
      </.link>
      <.link href={~p"/logout"} method="delete" class="side-link" id="logout">
        <.icon name="hero-arrow-right-start-on-rectangle" class="side-icon rtl:rotate-180" />
        <span>{gettext("Log out")}</span>
      </.link>
    </div>
    """
  end

  attr :locale, :string, default: "en"

  defp top_tools(assigns) do
    ~H"""
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
    <.theme_toggle />
    """
  end

  @doc """
  The sign-in pages (login, 2FA, account setup): a night panel with the brand beside a card
  with the form; on a phone the panel is a short band above it.
  """
  attr :flash, :map, required: true
  attr :locale, :string, default: "en"
  attr :platform?, :boolean, default: false
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="min-h-screen grid grid-rows-[auto_1fr] lg:grid-rows-1 lg:grid-cols-[minmax(380px,46%)_1fr] bg-base-200">
      <section class="on-night relative overflow-hidden bg-gradient-to-br from-night via-night to-night-2 text-on-night px-6 py-6 sm:px-10 lg:px-14 lg:py-12 flex flex-col gap-6">
        <div class="pointer-events-none absolute -top-24 -end-24 size-80 rounded-full bg-accent-bright/20 blur-3xl">
        </div>
        <div class="pointer-events-none absolute -bottom-32 -start-16 size-96 rounded-full bg-accent/10 blur-3xl">
        </div>

        <div class="relative flex items-center justify-between gap-4">
          <a href={~p"/login"} id="home-logo" aria-label="Q-PBX">
            <QPBX.Web.Logo.logo class="h-9 sm:h-10 w-auto" />
          </a>
          <div class="hidden lg:block" />
        </div>

        <div class="relative hidden sm:grid flex-1 place-items-center py-4" aria-hidden="true">
          <div class="relative size-56 lg:size-72">
            <svg viewBox="0 0 200 200" class="absolute inset-0 size-full overflow-visible">
              <circle cx="100" cy="100" r="96" class="orbit" />
              <circle cx="100" cy="100" r="80" class="ring ring-1" />
              <circle cx="100" cy="100" r="80" class="ring ring-2" />
              <circle cx="100" cy="100" r="80" class="ring ring-3" />
            </svg>
            <div class="absolute inset-0 grid place-items-center">
              <QPBX.Web.Logo.logo
                mark_only
                class="h-24 lg:h-28 w-auto drop-shadow-[0_0_24px_rgba(60,196,234,0.35)]"
              />
            </div>
          </div>
        </div>

        <div class="relative space-y-3">
          <h2 class="text-2xl lg:text-4xl font-semibold leading-tight max-w-[18ch] bg-gradient-to-r from-white via-[#c9eef9] to-accent-bright bg-clip-text text-transparent">
            {if @platform?,
              do: gettext("Run the whole platform from one place."),
              else: gettext("Your phone system, wherever you are.")}
          </h2>
          <p class="text-on-night-muted max-w-[42ch] hidden sm:block">
            {gettext(
              "Calls, voicemail and numbers for your whole team. Every change is live on the next call."
            )}
          </p>
          <ul class="hidden sm:flex flex-wrap gap-2 pt-2 text-sm">
            <li class="flex items-center gap-1.5 rounded-[6px] bg-white/8 border border-white/10 px-2.5 py-1">
              <.icon name="hero-bolt" class="size-4 text-accent" />{gettext("Instant changes")}
            </li>
            <li class="flex items-center gap-1.5 rounded-[6px] bg-white/8 border border-white/10 px-2.5 py-1">
              <.icon name="hero-shield-check" class="size-4 text-accent-bright" />{gettext(
                "Secure by default"
              )}
            </li>
            <li class="flex items-center gap-1.5 rounded-[6px] bg-white/8 border border-white/10 px-2.5 py-1">
              <.icon name="hero-language" class="size-4 text-accent-bright" />{gettext(
                "English and Arabic"
              )}
            </li>
          </ul>
        </div>
      </section>

      <section class="flex flex-col">
        <div class="flex justify-end items-center gap-2 p-4">
          <.top_tools locale={@locale} />
        </div>
        <div class="flex-1 grid place-items-center px-4 pb-12">
          <div class="w-full max-w-md rounded-[12px] border border-hairline bg-base-100 shadow-card p-6 sm:p-8 space-y-5">
            {render_slot(@inner_block)}
          </div>
        </div>
      </section>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  # The sidebar: pages grouped by what people come to do.
  defp nav_groups(%QPBX.Core.PlatformAdmin{}) do
    [
      {gettext("Overview"),
       [{gettext("Dashboard"), ~p"/platform", "nav-dashboard", "hero-squares-2x2"}]},
      {gettext("Customers"),
       [
         {gettext("Tenants"), ~p"/platform/tenants", "nav-tenants", "hero-building-office-2"},
         {gettext("Plans"), ~p"/platform/plans", "nav-plans", "hero-rectangle-stack"}
       ]},
      {gettext("Telephony"),
       [
         {gettext("Trunks"), ~p"/platform/trunks", "nav-trunks", "hero-server-stack"},
         {gettext("Numbers"), ~p"/platform/numbers", "nav-dids", "hero-hashtag"},
         {gettext("Numbering"), ~p"/platform/numbering", "nav-numbering", "hero-globe-alt"}
       ]},
      {gettext("Security"),
       [
         {gettext("SIP protection"), ~p"/platform/protection", "nav-protection",
          "hero-shield-check"},
         {gettext("Fraud protection"), ~p"/platform/fraud", "nav-fraud",
          "hero-shield-exclamation"},
         {gettext("Firewall"), ~p"/platform/firewall", "nav-firewall", "hero-fire"}
       ]},
      {gettext("Monitoring"),
       [
         {gettext("Alerts"), ~p"/platform/alerts", "nav-alerts", "hero-bell-alert"},
         {gettext("Audit log"), ~p"/platform/audit", "nav-audit", "hero-document-text"}
       ]},
      {gettext("Administration"),
       [
         {gettext("Platform admins"), ~p"/platform/admins", "nav-admins", "hero-user-group"},
         {gettext("API keys"), ~p"/platform/api-keys", "nav-api-keys", "hero-key"},
         {gettext("Notifications"), ~p"/platform/notifications", "nav-notifications", "hero-bell"}
       ]}
    ]
  end

  defp nav_groups(%QPBX.Core.User{} = user) do
    mine =
      {gettext("Me"),
       [
         {gettext("Dashboard"), ~p"/app", "nav-home", "hero-squares-2x2"},
         {gettext("My extension"), ~p"/app/me", "nav-me", "hero-phone"},
         {gettext("Notifications"), ~p"/app/notifications", "nav-notifications", "hero-bell"}
       ]}

    if tenant_admin?(user) do
      [
        mine,
        {gettext("Team"),
         [
           {gettext("Extensions"), ~p"/app/extensions", "nav-extensions",
            "hero-phone-arrow-up-right"},
           {gettext("Users"), ~p"/app/users", "nav-users", "hero-users"},
           {gettext("Voicemail"), ~p"/app/voicemail", "nav-voicemail", "hero-inbox"},
           {gettext("Calls"), ~p"/app/calls", "nav-calls", "hero-clock"}
         ]},
        {gettext("Routing"),
         [
           {gettext("Numbers"), ~p"/app/numbers", "nav-numbers", "hero-hashtag"},
           {gettext("Outbound routes"), ~p"/app/routes", "nav-routes", "hero-arrows-right-left"},
           {gettext("Number format"), ~p"/app/number-format", "nav-number-format",
            "hero-adjustments-horizontal"}
         ]},
        {gettext("Security"),
         [
           {gettext("Alerts"), ~p"/app/alerts", "nav-alerts", "hero-bell-alert"},
           {gettext("Office IPs"), ~p"/app/office-ips", "nav-office-ips", "hero-building-office"},
           {gettext("Audit log"), ~p"/app/audit", "nav-tenant-audit", "hero-document-text"}
         ]},
        {gettext("Integrations"),
         [
           {gettext("Webhooks"), ~p"/app/webhooks", "nav-webhooks", "hero-bolt"},
           {gettext("API keys"), ~p"/app/api-keys", "nav-api-keys", "hero-key"},
           {gettext("API explorer"), ~p"/v1/docs", "nav-api-docs", "hero-code-bracket"}
         ]}
      ]
    else
      [mine]
    end
  end

  defp initial(%{name: name}) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp initial(_), do: "?"

  defp tenant_admin?(%QPBX.Core.User{} = user), do: QPBX.Core.User.role(user) == "tenant_admin"

  defp notifications_path(%QPBX.Core.PlatformAdmin{}), do: ~p"/platform/notifications"
  defp notifications_path(_), do: ~p"/app/notifications"

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
