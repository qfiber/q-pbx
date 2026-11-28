import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/qpbx start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :qpbx, QPBX.Web.Endpoint, server: true
end

config :qpbx, QPBX.Web.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  config :qpbx, :sip_base_domain, System.fetch_env!("QPBX_SIP_BASE_DOMAIN")
  config :qpbx, :token_secret, System.fetch_env!("SECRET_KEY_BASE")

  config :qpbx, QPBX.Firewall,
    helper: QPBX.Firewall.Helper.Socket,
    socket: System.get_env("QPBX_FWD_SOCKET", "/run/qpbx-fwd/fwd.sock")

  config :qpbx, :health_token, System.get_env("QPBX_HEALTH_TOKEN")

  # Requests to tenant-chosen addresses (QPBX.Integrations.OutboundHTTP): plain HTTP only when
  # allowed; inside addresses only in the listed networks.
  config :qpbx, QPBX.Integrations,
    allow_http: System.get_env("QPBX_OUTBOUND_ALLOW_HTTP") == "true",
    allow_cidrs:
      System.get_env("QPBX_OUTBOUND_ALLOW_CIDRS", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

  config :qpbx, QPBX.Edge,
    jsonrpc_url: System.get_env("QPBX_KAMAILIO_JSONRPC_URL", "http://127.0.0.1:5071/RPC"),
    # Kamailio sends it with its registration reports (POST /internal/kamailio/registration).
    event_secret: System.get_env("QPBX_KAMAILIO_EVENT_SECRET")

  # Seconds; can only lower the 15-minute idle timeout (QPBX.Core.Sessions caps it).
  if idle = System.get_env("QPBX_SESSION_IDLE_TIMEOUT"),
    do: config(:qpbx, :session_idle_timeout, String.to_integer(idle))

  config :qpbx, QPBX.Web.Captcha,
    provider: String.to_existing_atom(System.get_env("QPBX_CAPTCHA_PROVIDER", "pow")),
    site_key: System.get_env("QPBX_CAPTCHA_SITE_KEY"),
    secret: System.get_env("QPBX_CAPTCHA_SECRET")

  config :qpbx, QPBX.Web.Health,
    interval: 10_000,
    disk: [paths: String.split(System.get_env("QPBX_HEALTH_DISK_PATHS", "/ /var/lib/qpbx"))],
    certificate: [
      path: System.get_env("QPBX_TLS_CERT_FILE"),
      tenants_dir: System.get_env("QPBX_TLS_TENANTS_DIR")
    ],
    freeswitch: [
      event_socket:
        {System.get_env("QPBX_FS_ESL_HOST", "127.0.0.1"),
         String.to_integer(System.get_env("QPBX_FS_ESL_PORT", "8021"))}
    ],
    kamailio: [
      jsonrpc_url: System.get_env("QPBX_KAMAILIO_JSONRPC_URL", "http://127.0.0.1:5071/RPC")
    ],
    # Status files written by the backup jobs (unset: backups not configured on this server).
    backups: [status_dir: System.get_env("QPBX_BACKUP_STATUS_DIR")]

  # Call control: the event socket to the local FreeSWITCH, and the password FreeSWITCH's
  # mod_xml_curl sends when asking for a dialplan.
  config :qpbx, QPBX.Telephony,
    esl: true,
    esl_host: System.get_env("QPBX_FS_ESL_HOST", "127.0.0.1"),
    esl_port: String.to_integer(System.get_env("QPBX_FS_ESL_PORT", "8021")),
    esl_password: System.fetch_env!("QPBX_FS_ESL_PASSWORD"),
    curl_password: System.fetch_env!("QPBX_FS_CURL_PASSWORD"),
    # FreeSWITCH's JSON CDR spool (mod_json_cdr), imported and emptied by CdrImporter.
    cdr_spool: System.get_env("QPBX_CDR_SPOOL", "/var/lib/qpbx/cdr-spool")

  config :qpbx, :mail_from, {"Q-PBX", System.fetch_env!("QPBX_MAIL_FROM")}

  # Username and password only when set: the adapter rejects a nil username, and a local
  # relay often needs no login.
  smtp_auth =
    case System.get_env("QPBX_SMTP_USERNAME") do
      # A login-free relay (often local) may lack TLS.
      user when user in [nil, ""] ->
        [auth: :never, tls: :if_available]

      # With a login, TLS is required so credentials never cross the network in clear.
      user ->
        [
          auth: :always,
          tls: :always,
          username: user,
          password: System.fetch_env!("QPBX_SMTP_PASSWORD")
        ]
    end

  config :qpbx,
         QPBX.Notify.Mailer,
         [
           adapter: Swoosh.Adapters.SMTP,
           relay: System.fetch_env!("QPBX_SMTP_HOST"),
           port: String.to_integer(System.get_env("QPBX_SMTP_PORT", "587"))
         ] ++ smtp_auth

  # Master key: local (QPBX_CLOAK_KEY) or AWS KMS (wrapped key file, unwrapped at start-up).
  key_provider =
    case System.get_env("QPBX_KEY_PROVIDER", "local") do
      "aws_kms" ->
        [
          source: :aws_kms,
          region: System.fetch_env!("QPBX_KMS_REGION"),
          key_id: System.fetch_env!("QPBX_KMS_KEY_ID"),
          blob_file: System.get_env("QPBX_KMS_BLOB_FILE", "/etc/qpbx/master-key.kms"),
          endpoint: System.get_env("QPBX_KMS_ENDPOINT")
        ]

      "local" ->
        [source: :local, key: System.fetch_env!("QPBX_CLOAK_KEY")]
    end

  config :qpbx, QPBX.Core.KeyProvider, key_provider

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # Encrypted files under the data folder; plain media only briefly in tmpfs shared with
  # FreeSWITCH (/run/qpbx-media).
  config :qpbx, QPBX.Storage,
    backend: QPBX.Storage.Local,
    root: System.get_env("QPBX_DATA_DIR", "/var/lib/qpbx"),
    temp_dir: System.get_env("QPBX_MEDIA_TMP", "/run/qpbx-media")

  config :qpbx, QPBX.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # nginx terminates TLS and proxies to the app on localhost only.
  config :qpbx, QPBX.Web.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
    server: true,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :qpbx, QPBX.Web.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :qpbx, QPBX.Web.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :qpbx, QPBX.Notify.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
