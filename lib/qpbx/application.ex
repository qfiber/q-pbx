defmodule QPBX.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Boundary, top_level?: true, deps: [QPBX.Repo, QPBX.Core, QPBX.Firewall, QPBX.Web]
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      QPBX.Web.Telemetry,
      QPBX.Repo,
      QPBX.Core.Vault,
      {Oban, Application.fetch_env!(:qpbx, Oban)},
      {Phoenix.PubSub, name: QPBX.PubSub},
      # Start a worker by calling: QPBX.Worker.start_link(arg)
      # {QPBX.Worker, arg},
      # Start to serve requests, typically the last entry
      QPBX.Core.SessionSweeper,
      QPBX.Firewall.Sync,
      QPBX.Web.Health,
      QPBX.Web.SessionReaper,
      QPBX.Web.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: QPBX.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    QPBX.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
