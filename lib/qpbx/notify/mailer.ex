defmodule QPBX.Notify.Mailer do
  @moduledoc "Swoosh mailer used only by the notify area."
  use Swoosh.Mailer, otp_app: :qpbx
end
