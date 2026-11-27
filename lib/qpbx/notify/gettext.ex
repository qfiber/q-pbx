defmodule QPBX.Notify.Gettext do
  @moduledoc "Email texts in English and Arabic."
  use Gettext.Backend, otp_app: :qpbx, priv: "priv/gettext_notify"
end
