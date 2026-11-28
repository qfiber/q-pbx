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
    plug QPBX.Web.CSP
    plug :fetch_current_account
  end

  pipeline :api do
    # csv: the call records export.
    plug :accepts, ["json", "csv"]
  end

  # Every /v1 request but the document: API key, then its rate limit.
  pipeline :api_key do
    plug QPBX.Web.Api.Auth
  end

  pipeline :health do
    plug :accepts, ["json"]
  end

  # FreeSWITCH (this server only): no session, no CSRF; the controller checks the source and
  # FreeSWITCH's password.
  scope "/internal/freeswitch", QPBX.Web do
    post "/dialplan", FreeswitchController, :dialplan
  end

  # Kamailio (this server only): registration reports; the controller checks the source and
  # the shared secret.
  scope "/internal/kamailio", QPBX.Web do
    post "/registration", KamailioController, :registration
  end

  scope "/health", QPBX.Web do
    pipe_through :health

    get "/", HealthController, :show
    get "/details", HealthController, :details
  end

  # The API's OpenAPI document and its explorer, public.
  scope "/v1", QPBX.Web.Api do
    pipe_through :api
    get "/openapi.json", SpecController, :show
  end

  scope "/v1", QPBX.Web.Api do
    pipe_through :browser
    get "/docs", SpecController, :docs
  end

  # A voicemail's audio for a short-lived signed link (the link is the permission).
  scope "/v1", QPBX.Web.Api do
    get "/voicemail-audio/:token", VoicemailAudioController, :show
  end

  # Every route here: API key and rate limit (pipeline), then scope and key kind from the
  # action's own description (QPBX.Web.Api.Authorize, in every API controller).
  scope "/v1", QPBX.Web.Api do
    pipe_through [:api, :api_key]

    get "/me", MeController, :show
    get "/api-keys", ApiKeyController, :index
    post "/api-keys", ApiKeyController, :create
    delete "/api-keys/:id", ApiKeyController, :delete
    get "/audit", AuditController, :index
    get "/alerts", AlertController, :index
    post "/alerts/test", AlertController, :test
    get "/alerts/:id", AlertController, :show
    post "/alerts/:id/acknowledge", AlertController, :acknowledge
    post "/alerts/:id/resolve", AlertController, :resolve
    get "/alerts/:id/notifications", AlertController, :deliveries
    post "/notifications/:id/resend", AlertController, :resend
    get "/alert-channels", AlertController, :channels
    post "/alert-channels", AlertController, :create_channel
    patch "/alert-channels/:id", AlertController, :update_channel
    delete "/alert-channels/:id", AlertController, :delete_channel
    get "/alert-rules", AlertController, :rules
    put "/alert-rules", AlertController, :put_rules

    # Platform
    get "/tenants", TenantController, :index
    post "/tenants", TenantController, :create
    get "/tenants/:id", TenantController, :show
    patch "/tenants/:id", TenantController, :update
    get "/tenants/:tenant_id/users", TenantController, :users
    post "/tenants/:tenant_id/users", TenantController, :add_admin
    post "/tenants/:tenant_id/users/:id/setup-link", TenantController, :setup_link
    post "/tenants/:tenant_id/users/:id/sign-out", TenantController, :sign_out
    get "/plans", PlanController, :index
    post "/plans", PlanController, :create
    get "/plans/:id", PlanController, :show
    patch "/plans/:id", PlanController, :update
    get "/trunks", TrunkController, :index
    post "/trunks", TrunkController, :create
    get "/trunks/:id", TrunkController, :show
    patch "/trunks/:id", TrunkController, :update
    delete "/trunks/:id", TrunkController, :delete
    post "/numbers", NumberController, :create
    patch "/numbers/:id", NumberController, :update
    delete "/numbers/:id", NumberController, :delete
    get "/number-classes", NumberingController, :classes
    post "/number-classes", NumberingController, :create_class
    delete "/number-classes/:id", NumberingController, :delete_class
    get "/emergency-routes", NumberingController, :emergency
    post "/emergency-routes", NumberingController, :create_emergency
    delete "/emergency-routes/:id", NumberingController, :delete_emergency
    get "/firewall", FirewallController, :index
    post "/firewall", FirewallController, :create
    delete "/firewall/:id", FirewallController, :delete
    get "/protection", ProtectionController, :show
    patch "/protection", ProtectionController, :update
    get "/protection/bans", ProtectionController, :bans
    delete "/protection/bans/:key", ProtectionController, :lift
    get "/fraud", ProtectionController, :fraud
    patch "/fraud", ProtectionController, :update_fraud
    get "/fraud/blocks", ProtectionController, :blocks
    delete "/fraud/blocks/:id", ProtectionController, :unblock
    get "/platform-admins", AdminController, :index
    post "/platform-admins", AdminController, :create
    post "/platform-admins/:id/setup-link", AdminController, :setup_link
    post "/platform-admins/:id/sign-out", AdminController, :sign_out

    # Both kinds: a platform key sees the platform's, a tenant key its own
    get "/numbers", NumberController, :index
    get "/numbers/:id", NumberController, :show
    get "/number-format", NumberingController, :format
    put "/number-format", NumberingController, :put_format

    # Tenant
    delete "/number-format", NumberingController, :reset_format
    put "/numbers/:id/destination", NumberController, :destination
    get "/extensions", ExtensionController, :index
    post "/extensions", ExtensionController, :create
    get "/extensions/:id", ExtensionController, :show
    patch "/extensions/:id", ExtensionController, :update
    delete "/extensions/:id", ExtensionController, :delete
    post "/extensions/:extension_id/devices", ExtensionController, :add_device
    delete "/devices/:id", ExtensionController, :delete_device
    post "/devices/:id/reset-password", ExtensionController, :reset_device
    get "/extensions/:extension_id/mailbox", VoicemailController, :mailbox
    put "/extensions/:extension_id/mailbox", VoicemailController, :put_mailbox
    delete "/extensions/:extension_id/mailbox", VoicemailController, :delete_mailbox
    get "/extensions/:extension_id/greetings", VoicemailController, :greetings
    put "/extensions/:extension_id/greetings/:kind", VoicemailController, :put_greeting
    delete "/extensions/:extension_id/greetings/:kind", VoicemailController, :delete_greeting
    get "/voicemails", VoicemailController, :index
    post "/voicemails/:id/save", VoicemailController, :save
    delete "/voicemails/:id", VoicemailController, :delete
    post "/voicemails/:id/audio-link", VoicemailController, :audio_link
    get "/users", UserController, :index
    post "/users", UserController, :create
    patch "/users/:id", UserController, :update
    delete "/users/:id", UserController, :delete
    post "/users/:id/setup-link", UserController, :setup_link
    post "/users/:id/sign-out", UserController, :sign_out
    get "/routes", RouteController, :index
    post "/routes", RouteController, :create
    get "/routes/:id", RouteController, :show
    patch "/routes/:id", RouteController, :update
    delete "/routes/:id", RouteController, :delete
    get "/office-ips", FirewallController, :office_ips
    post "/office-ips", FirewallController, :create_office_ip
    delete "/office-ips/:id", FirewallController, :delete_office_ip
    get "/calls", CallController, :index
    get "/calls/export", CallController, :export
    post "/calls", LiveCallController, :create
    get "/calls/live", LiveCallController, :index
    post "/calls/:id/hangup", LiveCallController, :hangup
    post "/calls/:id/transfer", LiveCallController, :transfer
    get "/usage/daily", CallController, :usage
    get "/webhooks", WebhookController, :index
    post "/webhooks", WebhookController, :create
    get "/webhooks/:id", WebhookController, :show
    patch "/webhooks/:id", WebhookController, :update
    delete "/webhooks/:id", WebhookController, :delete
    post "/webhooks/:id/rotate-secret", WebhookController, :rotate
    get "/webhooks/:id/deliveries", WebhookController, :deliveries
    get "/webhook-deliveries/:id", WebhookController, :delivery
    post "/webhook-deliveries/:id/resend", WebhookController, :resend
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

    # The acknowledge link in alert emails (the token is the permission).
    get "/alerts/ack/:link", AlertAckController, :show
    post "/alerts/ack/:link", AlertAckController, :confirm
  end

  scope "/platform", QPBX.Web.Platform do
    pipe_through [:browser, :require_platform_admin]

    live_session :platform_admin, on_mount: {QPBX.Web.Auth, :platform_admin} do
      live "/", TenantsLive, :index
      live "/tenants/new", TenantsLive, :new
      live "/tenants/:id", TenantLive, :show
      live "/admins", AdminsLive, :index
      live "/audit", AuditLive, :index
      live "/plans", PlansLive, :index
      live "/plans/:id", PlansLive, :edit
      live "/firewall", FirewallLive, :index
      live "/trunks", TrunksLive, :index
      live "/trunks/new", TrunksLive, :new
      live "/trunks/:id", TrunksLive, :edit
      live "/numbers", DidsLive, :index
      live "/numbering", NumberingLive, :index
      live "/protection", ProtectionLive, :index
      live "/fraud", FraudLive, :index

      # Shared page: full module name, not the surrounding scope's alias.
      scope "/", alias: false do
        live "/account", QPBX.Web.Account.SessionsLive, :index, as: :platform_account
        live "/api-keys", QPBX.Web.Account.ApiKeysLive, :index, as: :platform_api_keys

        live "/notifications", QPBX.Web.Account.NotificationsLive, :index,
          as: :platform_notifications

        live "/alerts", QPBX.Web.Account.AlertsLive, :index, as: :platform_alerts
      end
    end
  end

  scope "/app", QPBX.Web.Tenant do
    pipe_through [:browser, :require_tenant_user]

    # Decrypted audio, for tenant admins of the message's tenant (checked in the controller).
    get "/voicemail/:id/audio", QPBX.Web.VoicemailController, :audio, alias: false
    get "/calls/export", QPBX.Web.CallsController, :export, alias: false

    live_session :tenant_admin, on_mount: {QPBX.Web.Auth, :tenant_admin} do
      live "/extensions", ExtensionsLive, :index
      live "/extensions/:id", ExtensionLive, :show
      live "/extensions/:id/voicemail", MailboxLive, :show
      live "/voicemail", VoicemailLive, :index
      live "/calls", CallsLive, :index
      live "/users", UsersLive, :index
      live "/audit", AuditLive, :index
      live "/numbers", NumbersLive, :index
      live "/routes", RoutesLive, :index
      live "/office-ips", OfficeIpsLive, :index
      live "/number-format", NumberFormatLive, :index
      live "/webhooks", WebhooksLive, :index
      live "/webhooks/:id", WebhookLive, :show

      scope "/", alias: false do
        live "/api-keys", QPBX.Web.Account.ApiKeysLive, :index, as: :tenant_api_keys
        live "/alerts", QPBX.Web.Account.AlertsLive, :index, as: :tenant_alerts
      end
    end

    live_session :tenant_user, on_mount: {QPBX.Web.Auth, :tenant_user} do
      live "/", HomeLive, :index
      live "/me", MyExtensionLive, :index

      # Shared page: full module name, not the surrounding scope's alias.
      scope "/", alias: false do
        live "/account", QPBX.Web.Account.SessionsLive, :index, as: :tenant_account

        live "/notifications", QPBX.Web.Account.NotificationsLive, :index,
          as: :tenant_notifications
      end
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
