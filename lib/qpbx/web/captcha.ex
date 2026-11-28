defmodule QPBX.Web.Captcha do
  @moduledoc """
  Human check on the login and setup pages, chosen per installation
  (`config :qpbx, QPBX.Web.Captcha, provider: ..., site_key: ..., secret: ...`) and changeable
  by platform admins on the settings page (`/platform/settings`), which wins when set:

    * `:pow` (default): built-in proof of work, no outside service (ALTCHA format)
    * `:turnstile`: Cloudflare Turnstile
    * `:friendly_captcha`: Friendly Captcha v2
    * `:captcha_eu`: Captcha.eu
    * `:none`

  For the outside services a network failure or a 5xx counts as passed (and is logged), as
  Friendly Captcha's documentation advises: an outage there must not lock everyone out, and
  the per-IP limits still apply. A wrong or reused answer always fails.
  """
  use Phoenix.Component
  require Logger

  @callback verify(params :: map(), remote_ip :: :inet.ip_address()) :: :ok | {:error, term()}

  @providers %{
    pow: QPBX.Web.Captcha.Pow,
    turnstile: QPBX.Web.Captcha.Turnstile,
    friendly_captcha: QPBX.Web.Captcha.FriendlyCaptcha,
    captcha_eu: QPBX.Web.Captcha.CaptchaEU
  }

  def provider, do: config()[:provider] || :pow

  @doc """
  The installation's settings with the portal's on top (`QPBX.Core.platform_settings/0`: the
  provider, its site key and secret, each when set). If the settings cannot be read, the
  installation's alone: signing in must not depend on them.
  """
  def config do
    Keyword.merge(Application.get_env(:qpbx, __MODULE__, []), saved())
  end

  defp saved do
    s = QPBX.Core.platform_settings()

    [
      provider: s.captcha_provider && String.to_existing_atom(s.captcha_provider),
      site_key: s.captcha_site_key,
      secret: s.captcha_secret
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  rescue
    _ -> []
  end

  @doc "Checks the answer the form carried."
  def verify(params, remote_ip) do
    case @providers[provider()] do
      nil -> :ok
      mod -> mod.verify(params, remote_ip)
    end
  end

  @doc "Shared HTTP call for the outside services; network failures and 5xx count as passed."
  def remote_check(name, req_opts, success?) do
    case Req.post(
           [receive_timeout: 5_000, retry: false] ++ req_opts ++ (config()[:req_options] || [])
         ) do
      {:ok, %{status: 200, body: body}} ->
        if success?.(body), do: :ok, else: {:error, :rejected}

      {:ok, %{status: status}} when status >= 500 ->
        Logger.error("captcha #{name}: HTTP #{status}; letting the attempt through")
        :ok

      {:ok, %{status: status, body: body}} ->
        # 4xx: our key or request is wrong; refuse and make it visible.
        Logger.error("captcha #{name}: HTTP #{status} #{inspect(body)}")
        {:error, :misconfigured}

      {:error, e} ->
        Logger.error("captcha #{name}: #{Exception.message(e)}; letting the attempt through")
        :ok
    end
  end

  attr :form, :string, required: true, doc: "id of the protected form"

  attr :challenge, :any,
    default: nil,
    doc: "proof-of-work challenge from `QPBX.Web.Captcha.Pow.challenge/0`"

  @doc "The check's markup, placed inside the protected form."
  def widget(assigns) do
    assigns = assign(assigns, provider: provider(), site_key: config()[:site_key])

    ~H"""
    <%= case @provider do %>
      <% :pow -> %>
        <input type="hidden" name="pow" value="" data-pow-challenge={Jason.encode!(@challenge)} />
      <% :turnstile -> %>
        <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer>
        </script>
        <div class="cf-turnstile mb-2" data-sitekey={@site_key}></div>
      <% :friendly_captcha -> %>
        <script
          type="module"
          src="https://cdn.jsdelivr.net/npm/@friendlycaptcha/sdk@1.1.5/site.min.js"
          async
          defer
        >
        </script>
        <script
          nomodule
          src="https://cdn.jsdelivr.net/npm/@friendlycaptcha/sdk@1.1.5/site.compat.min.js"
          async
          defer
        >
        </script>
        <div class="frc-captcha mb-2" data-sitekey={@site_key}></div>
      <% :captcha_eu -> %>
        <script src="https://www.captcha.eu/sdk.js" defer>
        </script>
        <span data-captcha-eu-key={@site_key} data-captcha-eu-form={@form} hidden></span>
      <% _ -> %>
    <% end %>
    """
  end
end
