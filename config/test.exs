import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :qpbx, QPBX.Repo,
  # Not a superuser: superusers bypass row-level security.
  username: "qpbx",
  password: "qpbx",
  hostname: "localhost",
  database: "qpbx_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :qpbx, QPBX.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3BXo/2PcvQ7bIm/P/SqH1jJ89akvK9ZHaw2z1aMDz2DwJp65pQa9O+gKI6zAfg/V",
  server: false

# In test we don't send emails
config :qpbx, QPBX.Notify.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :qpbx, Oban, testing: :manual

# Checks run on demand in tests, not on a timer.
config :qpbx, QPBX.Web.Health, interval: :timer.hours(24)
config :qpbx, :health_token, "test-health-token-0123456789"

# Firewall: a fake helper; no timer-driven reconcile during tests.
config :qpbx, QPBX.Firewall,
  helper: QPBX.FakeHelper,
  reconcile_interval: :timer.hours(24),
  reconcile_on_start: false

# Tests of the login flow skip the human check; the captcha tests enable it themselves.
config :qpbx, QPBX.Web.Captcha, provider: :none

# The Kamailio reloader and ban carrier react to events and timers; tests call them directly.
config :qpbx, :edge_workers, false
