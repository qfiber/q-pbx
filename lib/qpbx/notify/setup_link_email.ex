defmodule QPBX.Notify.SetupLinkEmail do
  @moduledoc "Oban worker that emails an account setup link."
  use Oban.Worker, queue: :notify, max_attempts: 10
  use Gettext, backend: QPBX.Notify.Gettext
  import Swoosh.Email

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"email" => email, "name" => name, "locale" => locale, "url" => url}
      }) do
    case email |> build(name, locale, url) |> QPBX.Notify.Mailer.deliver() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def build(email, name, locale, url) do
    Gettext.with_locale(QPBX.Notify.Gettext, locale, fn ->
      dir = if locale == "ar", do: "rtl", else: "ltr"
      greeting = gettext("Hello %{name},", name: name)

      body =
        gettext(
          "An account was created for you on Q-PBX. Open this link to choose your password and set up two-factor authentication:"
        )

      expiry = gettext("The link works once and expires in 48 hours.")

      new()
      |> to({name, email})
      |> from(sender())
      |> subject(gettext("Set up your Q-PBX account"))
      |> text_body("#{greeting}\n\n#{body}\n\n#{url}\n\n#{expiry}\n")
      |> html_body("""
      <div dir="#{dir}"><p>#{esc(greeting)}</p><p>#{esc(body)}</p>
      <p><a href="#{esc(url)}">#{esc(url)}</a></p><p>#{esc(expiry)}</p></div>
      """)
    end)
  end

  defp esc(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  defp sender, do: Application.get_env(:qpbx, :mail_from, {"Q-PBX", "noreply@localhost"})
end
