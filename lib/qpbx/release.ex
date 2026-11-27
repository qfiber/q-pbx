defmodule QPBX.Release do
  @moduledoc """
  Commands for the release CLI, run with `bin/qpbx eval`. They start only the database and the
  vault, never the web server, so they work next to a running node.

      bin/qpbx eval 'QPBX.Release.migrate()'
      bin/qpbx eval 'QPBX.Release.create_platform_admin("ops@example.com", "Ops")'
      bin/qpbx eval 'QPBX.Release.setup_link("user@example.com")'
  """
  use Boundary, top_level?: true, deps: [QPBX.Repo, QPBX.Core, QPBX.Web]

  @app :qpbx
  @actor {:system, "cli"}

  def migrate do
    load()

    for repo <- Application.fetch_env!(@app, :ecto_repos),
        do: {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
  end

  @doc "Creates a platform admin and prints their setup link."
  def create_platform_admin(email, name) do
    with_db(fn ->
      case QPBX.Core.create_platform_admin(%{email: email, name: name}, @actor) do
        {:ok, admin} -> print_link(admin)
        {:error, cs} -> fail(inspect(cs.errors))
      end
    end)
  end

  @doc "Prints a fresh setup link for an existing platform admin or tenant user (email)."
  def setup_link(email) do
    with_db(fn ->
      case QPBX.Core.find_account_by_email(email) do
        nil -> fail("no account with email #{email}")
        account -> print_link(account)
      end
    end)
  end

  defp print_link(account) do
    {:ok, _} = QPBX.Core.audit(@actor, "account.setup_link_issued", account, %{})
    IO.puts(QPBX.Web.setup_url(QPBX.Core.setup_token(account)))
  end

  @spec fail(String.t()) :: no_return()
  defp fail(message) do
    IO.puts(:stderr, "error: " <> message)
    System.halt(1)
  end

  defp with_db(fun) do
    load()
    {:ok, _} = Application.ensure_all_started(:cloak_ecto)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(QPBX.Repo, fn _repo ->
        case QPBX.Core.Vault.start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        fun.()
      end)
  end

  defp load, do: Application.load(@app)
end
