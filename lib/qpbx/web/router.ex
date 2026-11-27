defmodule QPBX.Web.Router do
  use QPBX.Web, :router

  import QPBX.Web.Auth,
    only: [fetch_current_account: 2, require_platform_admin: 2, require_tenant_user: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug QPBX.Web.Locale
    plug :put_root_layout, html: {QPBX.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_account
  end

  pipeline :health do
    plug :accepts, ["json"]
  end

  scope "/health", QPBX.Web do
    pipe_through :health

    get "/", HealthController, :show
    get "/details", HealthController, :details
  end

  scope "/", QPBX.Web do
    pipe_through :browser

    get "/", PageController, :home
    get "/locale/:locale", LocaleController, :update

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/platform/login", SessionController, :new
    post "/platform/login", SessionController, :create
    delete "/logout", SessionController, :delete

    get "/2fa", TotpController, :show
    post "/2fa", TotpController, :verify
    get "/2fa/setup", TotpController, :setup
    post "/2fa/setup", TotpController, :enable
    post "/2fa/skip", TotpController, :skip

    get "/setup/:token", SetupController, :show
    put "/setup/:token", SetupController, :update
  end

  scope "/platform", QPBX.Web.Platform do
    pipe_through [:browser, :require_platform_admin]

    live_session :platform_admin, on_mount: {QPBX.Web.Auth, :platform_admin} do
      live "/", TenantsLive, :index
      live "/tenants/new", TenantsLive, :new
      live "/plans", PlansLive, :index
      live "/firewall", FirewallLive, :index
    end
  end

  scope "/app", QPBX.Web.Tenant do
    pipe_through [:browser, :require_tenant_user]

    live_session :tenant_user, on_mount: {QPBX.Web.Auth, :tenant_user} do
      live "/", HomeLive, :index
    end
  end

  if Application.compile_env(:qpbx, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: QPBX.Web.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
