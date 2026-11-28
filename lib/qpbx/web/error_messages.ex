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
      dgettext_noop("errors", "must be in the future"),
      dgettext_noop("errors", "pick at least one scope"),
      dgettext_noop("errors", "pick at least one event"),
      dgettext_noop("errors", "must start with https://"),
      dgettext_noop("errors", "points to an internal address"),
      dgettext_noop("errors", "has a host name that does not resolve"),
      dgettext_noop("errors", "is not a valid URL"),
      dgettext_noop("errors", "pick at least one category"),
      dgettext_noop("errors", "has an unknown category or channel"),
      dgettext_noop("errors", "must be percentages from 1 to 100")
    ]
  end
end
