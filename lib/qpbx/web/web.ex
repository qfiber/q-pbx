defmodule QPBX.Web do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use QPBX.Web, :controller
      use QPBX.Web, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  use Boundary,
    # Repo only for the health check's SELECT 1 and Oban backlog count; no area tables.
    deps: [
      QPBX.Core,
      QPBX.Notify,
      QPBX.Firewall,
      QPBX.Edge,
      QPBX.Telephony,
      QPBX.Events,
      QPBX.Repo
    ],
    exports: [Endpoint, Telemetry, Health]

  @doc """
  Absolute URL of an account setup link. Built from config rather than the running endpoint,
  so the release CLI can print links without starting the web server.
  """
  def setup_url(token) do
    url = Application.get_env(:qpbx, QPBX.Web.Endpoint)[:url] || []
    scheme = url[:scheme] || "http"
    port = url[:port]
    default_port? = port in [nil, 80, 443]
    host = url[:host] || "localhost"
    "#{scheme}://#{host}#{if default_port?, do: "", else: ":#{port}"}/setup/#{token}"
  end

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt theme.js)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: QPBX.Web.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: QPBX.Web.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import QPBX.Web.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias QPBX.Web.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: QPBX.Web.Endpoint,
        router: QPBX.Web.Router,
        statics: QPBX.Web.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
