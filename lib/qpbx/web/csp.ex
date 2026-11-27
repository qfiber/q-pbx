defmodule QPBX.Web.CSP do
  @moduledoc """
  Content-Security-Policy for every portal page: scripts only from this site (no inline
  scripts, no eval), plus the configured human-check provider's own domains; no framing of
  the portal; forms post only to this site. Styles allow inline attributes because LiveView
  sets them when showing and hiding elements.
  """
  @behaviour Plug
  import Plug.Conn

  # Per provider: [script, connect, frame, worker] sources it needs.
  @providers %{
    turnstile: %{
      script: ["https://challenges.cloudflare.com"],
      connect: [],
      frame: ["https://challenges.cloudflare.com"]
    },
    friendly_captcha: %{
      script: ["https://cdn.jsdelivr.net", "'wasm-unsafe-eval'"],
      connect: ["https://global.frcapi.com"],
      frame: []
    },
    captcha_eu: %{
      script: ["https://www.captcha.eu"],
      connect: ["https://www.captcha.eu"],
      frame: []
    }
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts),
    do: put_resp_header(conn, "content-security-policy", policy(QPBX.Web.Captcha.provider()))

  @doc "The policy string for a human-check provider."
  def policy(provider) do
    extra = Map.get(@providers, provider, %{script: [], connect: [], frame: []})

    [
      "default-src 'self'",
      Enum.join(["script-src 'self'" | extra.script], " "),
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      "font-src 'self'",
      Enum.join(["connect-src 'self'" | extra.connect], " "),
      if(extra.frame == [],
        do: "frame-src 'none'",
        else: Enum.join(["frame-src" | extra.frame], " ")
      ),
      "worker-src 'self' blob:",
      "object-src 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "frame-ancestors 'none'"
    ]
    |> Enum.join("; ")
  end
end
