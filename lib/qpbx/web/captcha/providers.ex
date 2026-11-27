defmodule QPBX.Web.Captcha.Turnstile do
  @moduledoc "Cloudflare Turnstile: tokens last 5 minutes and are single use."
  @behaviour QPBX.Web.Captcha
  alias QPBX.Web.Captcha

  @impl true
  def verify(%{"cf-turnstile-response" => token}, ip) when is_binary(token) and token != "" do
    Captcha.remote_check(
      "turnstile",
      [
        url: "https://challenges.cloudflare.com/turnstile/v0/siteverify",
        form: [
          secret: Captcha.config()[:secret],
          response: token,
          remoteip: :inet.ntoa(ip) |> to_string()
        ]
      ],
      &(&1["success"] == true)
    )
  end

  def verify(_, _), do: {:error, :missing}
end

defmodule QPBX.Web.Captcha.FriendlyCaptcha do
  @moduledoc "Friendly Captcha v2: the API key goes in the X-API-Key header; responses are single use."
  @behaviour QPBX.Web.Captcha
  alias QPBX.Web.Captcha

  @impl true
  def verify(%{"frc-captcha-response" => token}, _ip) when is_binary(token) and token != "" do
    Captcha.remote_check(
      "friendly_captcha",
      [
        url: "https://global.frcapi.com/api/v2/captcha/siteverify",
        headers: [{"x-api-key", Captcha.config()[:secret]}],
        json: %{response: token, sitekey: Captcha.config()[:site_key]}
      ],
      &(&1["success"] == true)
    )
  end

  def verify(_, _), do: {:error, :missing}
end

defmodule QPBX.Web.Captcha.CaptchaEU do
  @moduledoc "Captcha.eu: the solution is posted unchanged with the REST key in the Rest-Key header."
  @behaviour QPBX.Web.Captcha
  alias QPBX.Web.Captcha

  @impl true
  def verify(%{"captcha_at_solution" => solution}, _ip)
      when is_binary(solution) and solution != "" do
    Captcha.remote_check(
      "captcha_eu",
      [
        url: "https://www.captcha.eu/validate",
        headers: [{"content-type", "application/json"}, {"rest-key", Captcha.config()[:secret]}],
        body: solution
      ],
      &(is_map(&1) and &1["success"] == true)
    )
  end

  def verify(_, _), do: {:error, :missing}
end
