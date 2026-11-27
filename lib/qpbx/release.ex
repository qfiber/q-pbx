defmodule QPBX.Release do
  @moduledoc """
  Commands for the release CLI, run with `bin/qpbx eval`. They start only the database and the
  vault, never the web server, so they work next to a running node.

      bin/qpbx eval 'QPBX.Release.migrate()'
      bin/qpbx eval 'QPBX.Release.create_platform_admin("ops@example.com", "Ops")'
      bin/qpbx eval 'QPBX.Release.setup_link("user@example.com")'
  """
  use Boundary, top_level?: true, deps: [QPBX.Repo, QPBX.Core, QPBX.Firewall, QPBX.Web]

  @app :qpbx
  @actor {:system, "cli"}

  @doc """
  Runs migrations. In production they connect as the schema owner
  (`MIGRATION_DATABASE_URL`); the app itself connects as a role without schema rights.
  """
  def migrate do
    load()

    # Only this short-lived migration process connects as the owner; with_repo/3 does not take
    # connection options, so the repo's configuration is changed here.
    if url = System.get_env("MIGRATION_DATABASE_URL") do
      config = Application.get_env(@app, QPBX.Repo, [])
      Application.put_env(@app, QPBX.Repo, Keyword.put(config, :url, url))
    end

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

  @doc """
  Adds management IPs (platform allow, scope all) if the database has none yet. Run by the
  Ansible role after install with the inventory's management IPs, so the first sync never
  removes the SSH access the base ruleset was seeded with.
  """
  def seed_management_ips(cidrs) when is_list(cidrs) do
    with_db(fn ->
      existing = QPBX.Firewall.list_entries(level: "platform")

      if Enum.any?(existing, &QPBX.Firewall.Entry.management?/1),
        do: IO.puts("management IPs already present; nothing to do"),
        else: Enum.each(cidrs, &add_management_ip/1)
    end)
  end

  defp add_management_ip(cidr) do
    attrs = %{
      level: "platform",
      kind: "allow",
      scope: "all",
      cidr: cidr,
      reason: "management IP from Ansible inventory"
    }

    case QPBX.Firewall.create_entry(attrs, {:system, "ansible"}) do
      {:ok, e} -> IO.puts("added #{e.cidr}")
      {:error, cs} -> fail("#{cidr}: #{inspect(cs.errors)}")
    end
  end

  @doc """
  Wraps the current local master key with AWS KMS and prints the blob (base64) for the server
  to keep in place of the plain key. Data stays readable: the key itself does not change.
  Needs AWS credentials and `QPBX_KMS_REGION`/`QPBX_KMS_KEY_ID` (optional `QPBX_KMS_ENDPOINT`).
  """
  def kms_wrap_key do
    load()

    opts = [
      region: System.fetch_env!("QPBX_KMS_REGION"),
      key_id: System.fetch_env!("QPBX_KMS_KEY_ID"),
      endpoint: System.get_env("QPBX_KMS_ENDPOINT")
    ]

    {:ok, _} = Application.ensure_all_started(:req)
    key = Base.decode64!(System.fetch_env!("QPBX_CLOAK_KEY"))

    case QPBX.Core.KeyProvider.wrap(key, opts) do
      {:ok, blob} -> IO.puts(blob)
      {:error, reason} -> fail("KMS wrap failed: #{inspect(reason)}")
    end
  end

  @doc "Prints every tenant SIP domain, one per line (for per-hostname certificates)."
  def list_sip_domains do
    with_db(fn -> Enum.each(QPBX.Core.list_tenants(), &IO.puts(&1.sip_domain)) end)
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

  # Outside a running node (bin/qpbx eval): start only what the commands need. Firewall changes
  # made here reach nftables through the live node's 60 s reconcile.
  defp with_db(fun) do
    load()
    # plug_crypto: its key cache (an ETS table) is needed to sign setup links.
    # req: the vault may fetch its key from AWS KMS.
    {:ok, _} = Application.ensure_all_started([:cloak_ecto, :phoenix_pubsub, :plug_crypto, :req])

    case Supervisor.start_link([], strategy: :one_for_one, name: QPBX.Release.Sup) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, _, _} =
      Ecto.Migrator.with_repo(QPBX.Repo, fn _repo ->
        Enum.each([QPBX.Core.Vault, {Phoenix.PubSub, name: QPBX.PubSub}], &start_child/1)

        fun.()
      end)
  end

  defp start_child(child) do
    case Supervisor.start_child(QPBX.Release.Sup, child) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp load, do: Application.load(@app)
end
