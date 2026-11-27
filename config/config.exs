# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :qpbx,
  namespace: QPBX,
  ecto_repos: [QPBX.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :qpbx, QPBX.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: QPBX.Web.ErrorHTML, json: QPBX.Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: QPBX.PubSub,
  live_view: [signing_salt: "nn2gsyFt"]

# Portal and email languages. Adding one: its .po files under priv/gettext/<code>/ and
# priv/gettext_notify/<code>/ (mix gettext.merge ... --locale <code>), plus one line here.
config :qpbx, :locales, [
  %{code: "en", name: "English", dir: "ltr"},
  %{code: "ar", name: "العربية", dir: "rtl"}
]

# Bundled IANA data (no network updates on the server); tenant time zones need it.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Tenant SIP domains are <slug>.<sip_base_domain>. Overridden at runtime in prod.
config :qpbx, :sip_base_domain, "pbx.example.test"

# Dev/test only; prod sets both from the environment in runtime.exs.
config :qpbx, :token_secret, "dev-only-token-secret-not-for-production-use-0123456789abcdef"

config :qpbx, QPBX.Core.KeyProvider,
  source: :local,
  key: "jrcZoMY+Y6K9i05XDiUi13d5vWK8dXuMD56+Vnfw+qA="

# Health checks. FreeSWITCH, Kamailio and the certificate count only where configured
# (prod: runtime.exs from QPBX_* environment variables).
config :qpbx, QPBX.Web.Health, interval: 10_000, disk: [paths: ["/"]]

# Human check on login and setup pages: :pow (built-in, default), :turnstile, :friendly_captcha,
# :captcha_eu or :none. Outside services need site_key and secret (runtime.exs in prod).
config :qpbx, QPBX.Web.Captcha, provider: :pow

# Oban: one queue per area (spec: calls, fax, webhooks, notify, crm, provisioning).
# Phase 1 only has work for notify; the others are added with their areas.
config :qpbx, Oban,
  engine: Oban.Engines.Basic,
  repo: QPBX.Repo,
  queues: [notify: 5],
  # Completed jobs (which carry setup links) are deleted after a day.
  plugins: [{Oban.Plugins.Pruner, max_age: 86_400}]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :qpbx, QPBX.Notify.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  qpbx: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  qpbx: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
