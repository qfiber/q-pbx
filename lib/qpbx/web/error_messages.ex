defmodule QPBX.Web.ErrorMessages do
  @moduledoc """
  Validation messages written in other areas (for example `QPBX.Core` changesets). Listed here
  only so `mix gettext.extract` picks them up for translation; `translate_error/1` looks them
  up in the "errors" domain at runtime.
  """
  use Gettext, backend: QPBX.Web.Gettext

  def messages do
    [
      dgettext_noop("errors", "does not match"),
      dgettext_noop(
        "errors",
        "lowercase letters, digits and dashes, not starting or ending with a dash"
      ),
      dgettext_noop("errors", "must be a valid email"),
      dgettext_noop("errors", "is not a known time zone"),
      dgettext_noop("errors", "is not a valid IP address or prefix"),
      dgettext_noop("errors", "must be empty for platform entries"),
      dgettext_noop("errors", "tenants can only add allow entries"),
      dgettext_noop("errors", "tenant entries are for SIP only"),
      dgettext_noop("errors", "is too wide for a tenant entry (at most /%{min})"),
      dgettext_noop("errors", "must be in the future")
    ]
  end
end
