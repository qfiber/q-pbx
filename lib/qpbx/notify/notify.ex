defmodule QPBX.Notify do
  @moduledoc """
  Public API of the notify area. Phase 1 holds only the account setup-link email.
  See `lib/qpbx/notify/README.md`.
  """
  use Boundary, deps: [QPBX.Storage], exports: []

  alias QPBX.Notify.{SetupLinkEmail, VoicemailEmail}

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

  @doc """
  Queues the email for a new voicemail. `vm`: email, locale, extension, caller, caller_name,
  duration, at, format, and file_key (nil: no audio attached).
  """
  def deliver_voicemail(%{email: email} = vm) when is_binary(email) do
    vm
    |> Map.take([
      :email,
      :locale,
      :extension,
      :caller,
      :caller_name,
      :duration,
      :format,
      :file_key
    ])
    |> Map.put(:at, vm.at |> DateTime.truncate(:second) |> DateTime.to_iso8601())
    |> VoicemailEmail.new()
    |> Oban.insert()
  end
end
