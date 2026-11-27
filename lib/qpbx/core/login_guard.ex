defmodule QPBX.Core.LoginGuard do
  @moduledoc """
  Failed-login limits per client IP: 5 failures block the IP for 1 hour; 5 more after that
  block it for 24 hours. Strikes are forgotten after 24 hours without a failure. Accounts are
  never locked: 5 failures on one account write an alert entry to the audit log instead (real
  alerts arrive with notifications in phase 3). Counters live in the database, so they hold
  across restarts and across servers.
  """
  import Ecto.Query
  require Logger
  alias QPBX.Core.Audit
  alias QPBX.Repo

  @limit 5
  @first_block 3600
  @next_block 24 * 3600
  @forget_after 24 * 3600

  defmodule Failure do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:key, :string, autogenerate: false}
    schema "login_failures" do
      field :failures, :integer, default: 0
      field :strikes, :integer, default: 0
      field :blocked_until, :utc_datetime
      field :last_failure_at, :utc_datetime
    end
  end

  @doc "`:ok`, or `{:blocked, until}` while the IP is blocked."
  def check(ip) do
    case Repo.get(Failure, ip_key(ip)) do
      %Failure{blocked_until: %DateTime{} = until} = f ->
        if future?(until), do: {:blocked, f.blocked_until}, else: :ok

      _ ->
        :ok
    end
  end

  @doc "Records a failure from `ip` (and for `account`, if known). Returns `:ok` or `{:blocked, until}`."
  def failure(ip, account \\ nil) do
    if account, do: count_account(account)

    {:ok, result} = Repo.transaction(fn -> record(ip_key(ip), now()) end)
    result
  end

  defp record(key, now) do
    f =
      Repo.one(from(x in Failure, where: x.key == ^key, lock: "FOR UPDATE")) || %Failure{key: key}

    f = forget_if_quiet(f, now)
    f = maybe_block(%{f | failures: f.failures + 1, last_failure_at: now}, now)
    Repo.insert!(f, on_conflict: :replace_all, conflict_target: :key)
    if f.blocked_until && future?(f.blocked_until), do: {:blocked, f.blocked_until}, else: :ok
  end

  # A long quiet period wipes earlier strikes.
  defp forget_if_quiet(%Failure{last_failure_at: %DateTime{} = last} = f, now) do
    if DateTime.diff(now, last) > @forget_after, do: %{f | strikes: 0, failures: 0}, else: f
  end

  defp forget_if_quiet(f, _now), do: f

  defp maybe_block(%Failure{failures: n} = f, now) when n >= @limit do
    strikes = f.strikes + 1
    duration = if strikes == 1, do: @first_block, else: @next_block

    Logger.warning(
      "login: blocking #{f.key} for #{div(duration, 3600)} h after #{@limit} failures"
    )

    %{f | failures: 0, strikes: strikes, blocked_until: DateTime.add(now, duration)}
  end

  defp maybe_block(f, _now), do: f

  @doc "A successful login from `ip`: its failure count starts over (strikes stay until they expire)."
  def success(ip) do
    Repo.update_all(from(x in Failure, where: x.key == ^ip_key(ip)), set: [failures: 0])
    :ok
  end

  @doc "Removes counters with no failure for 48 hours and no active block."
  def sweep do
    cutoff = DateTime.add(now(), -2 * @forget_after)
    now = now()

    Repo.delete_all(
      from x in Failure,
        where: x.last_failure_at < ^cutoff and (is_nil(x.blocked_until) or x.blocked_until < ^now)
    )
  end

  defp count_account(account) do
    key = "account:#{account.__struct__ |> Module.split() |> List.last()}:#{account.id}"
    now = now()

    {_, [f]} =
      Repo.insert_all(Failure, [%{key: key, failures: 1, strikes: 0, last_failure_at: now}],
        on_conflict: [inc: [failures: 1], set: [last_failure_at: now]],
        conflict_target: :key,
        returning: [:failures]
      )

    if rem(f.failures, @limit) == 0 do
      Logger.warning("login: #{f.failures} failed attempts on #{key}")

      {:ok, _} =
        Repo.insert(
          Audit.entry({:system, "login-guard"}, "account.login_failures_alert", account, %{
            failures: f.failures
          })
        )
    end
  end

  defp ip_key(ip) when is_tuple(ip), do: "ip:" <> (ip |> :inet.ntoa() |> to_string())
  defp ip_key(ip) when is_binary(ip), do: "ip:" <> ip
  defp future?(at), do: DateTime.compare(at, DateTime.utc_now()) == :gt
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
