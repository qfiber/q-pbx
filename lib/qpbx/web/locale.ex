defmodule QPBX.Web.Locale do
  @moduledoc "Sets the Gettext locale from the session (en or ar) and exposes it to layouts."
  import Plug.Conn

  @locales ~w(en ar)

  def locales, do: @locales
  def dir("ar"), do: "rtl"
  def dir(_), do: "ltr"

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = if get_session(conn, :locale) in @locales, do: get_session(conn, :locale), else: "en"
    Gettext.put_locale(QPBX.Web.Gettext, locale)
    assign(conn, :locale, locale)
  end
end
