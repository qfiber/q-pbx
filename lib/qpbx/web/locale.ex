defmodule QPBX.Web.Locale do
  @moduledoc """
  Sets the Gettext locale from the session and exposes it to layouts. The offered languages
  come from `config :qpbx, :locales` (code, name in that language, text direction).
  """
  import Plug.Conn

  def all, do: Application.fetch_env!(:qpbx, :locales)
  def codes, do: Enum.map(all(), & &1.code)
  def default, do: hd(codes())

  def dir(code) do
    case Enum.find(all(), &(&1.code == code)) do
      %{dir: dir} -> dir
      nil -> "ltr"
    end
  end

  @doc "`{name, code}` pairs for select inputs."
  def options, do: Enum.map(all(), &{&1.name, &1.code})

  def init(opts), do: opts

  def call(conn, _opts) do
    locale =
      if get_session(conn, :locale) in codes(), do: get_session(conn, :locale), else: default()

    Gettext.put_locale(QPBX.Web.Gettext, locale)
    assign(conn, :locale, locale)
  end
end
