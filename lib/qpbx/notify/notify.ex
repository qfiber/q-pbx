defmodule QPBX.Notify do
  @moduledoc """
  Public API of the notify area. Phase 1 holds only the account setup-link email.
  See `lib/qpbx/notify/CLAUDE.md`.
  """
  use Boundary, deps: [], exports: []

  alias QPBX.Notify.SetupLinkEmail

  @doc """
  Queues the setup-link email (Oban queue `notify`). `account` needs `email`, `name` and
  `locale` (nil falls back to English).
  """
  def deliver_setup_link(%{email: email, name: name} = account, url) when is_binary(url) do
    %{
      "email" => email,
      "name" => name,
      "locale" => Map.get(account, :locale) || "en",
      "url" => url
    }
    |> SetupLinkEmail.new()
    |> Oban.insert()
  end
end
