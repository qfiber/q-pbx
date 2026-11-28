defmodule QPBX.Core.Sessions do
  @moduledoc """
  Server-side sessions: checked on every request, ended after `idle_timeout/0` without
  activity or 12 hours after login, and revocable at once. Revocations publish
  `QPBX.Events.SessionsRevoked` so live pages disconnect immediately.
  """
  import Ecto.Query
  alias QPBX.Core.{Audit, PlatformAdmin, User, UserSession}
  alias QPBX.Events
  alias QPBX.Events.SessionsRevoked
  alias QPBX.Repo

  @max_idle 15 * 60
  @max_age 12 * 3600
  # Write "last seen" at most this often; every request is still checked.
  @touch_every 30

  @doc "Idle timeout in seconds: configurable lower than 15 minutes, never higher."
  def idle_timeout,
    do: min(Application.get_env(:qpbx, :session_idle_timeout, @max_idle), @max_idle)

  @doc "Starts a session. Returns `{token, session}`; the token goes in the cookie only."
  def create(account, meta \\ %{}) do
    token = :crypto.strong_rand_bytes(32)
    now = now()

    session =
      Repo.insert!(%UserSession{
        token_hash: hash(token),
        account_type: type(account),
        account_id: account.id,
        tenant_id: Map.get(account, :tenant_id),
        ip: meta[:ip],
        user_agent: meta[:user_agent] && String.slice(meta[:user_agent], 0, 255),
        last_seen_at: now,
        expires_at: DateTime.add(now, @max_age)
      })

    note_ip(account, meta[:ip])
    {Base.url_encode64(token, padding: false), session}
  end

  # A login from an address this account has not used lately is a security alert (not on
  # the very first login). The last 10 addresses are kept.
  defp note_ip(_account, nil), do: :ok

  defp note_ip(%{login_ips: known} = account, ip) do
    if known != [] and ip not in known do
      Events.publish(%QPBX.Events.LoginAlert{
        kind: "new_ip",
        account_type: type(account),
        account_id: account.id,
        tenant_id: Map.get(account, :tenant_id),
        ip: ip,
        at: DateTime.utc_now()
      })
    end

    ips = Enum.take([ip | List.delete(known, ip)], 10)

    Repo.update_all(from(a in account.__struct__, where: a.id == ^account.id),
      set: [login_ips: ips]
    )

    :ok
  end

  defp note_ip(_account, _ip), do: :ok

  @doc """
  Checks a token: returns `{:ok, account, session}` while the session is live, and records
  activity (pass `touch: false` for checks that are not user activity). Ends a session that
  ran out.
  """
  def fetch(token, opts \\ [])

  def fetch(token, opts) when is_binary(token) do
    with {:ok, raw} <- Base.url_decode64(token, padding: false),
         %UserSession{} = s <- Repo.get_by(UserSession, token_hash: hash(raw)),
         :ok <- live?(s),
         %{} = account <- load(s) do
      {:ok, account, maybe_touch(s, Keyword.get(opts, :touch, true))}
    else
      {:expired, s} ->
        delete_and_publish(from(x in UserSession, where: x.id == ^s.id))
        :error

      _ ->
        :error
    end
  end

  def fetch(_, _), do: :error

  defp live?(s) do
    now = now()
    idle = DateTime.diff(now, s.last_seen_at)

    if idle <= idle_timeout() and DateTime.compare(now, s.expires_at) == :lt,
      do: :ok,
      else: {:expired, s}
  end

  defp maybe_touch(s, false), do: s

  defp maybe_touch(s, true) do
    if DateTime.diff(now(), s.last_seen_at) >= @touch_every do
      now = now()
      Repo.update_all(from(x in UserSession, where: x.id == ^s.id), set: [last_seen_at: now])
      %{s | last_seen_at: now}
    else
      s
    end
  end

  def list(account) do
    Repo.all(
      from s in UserSession,
        where: s.account_type == ^type(account) and s.account_id == ^account.id,
        order_by: [desc: s.last_seen_at]
    )
  end

  @doc "Ends one session of `account` (its own sessions only)."
  def revoke(account, session_id, actor) do
    query =
      from s in UserSession,
        where:
          s.id == ^session_id and s.account_type == ^type(account) and s.account_id == ^account.id

    audited(actor, "session.revoke", account, query)
  end

  @doc "Ends every session of `account`, optionally keeping one (\"sign out everywhere else\")."
  def revoke_all(account, actor, opts \\ []) do
    query =
      from s in UserSession,
        where: s.account_type == ^type(account) and s.account_id == ^account.id

    query =
      case Keyword.get(opts, :except) do
        nil -> query
        keep -> from s in query, where: s.id != ^keep
      end

    audited(actor, "session.revoke_all", account, query)
  end

  @doc "Ends the session behind a token (log out)."
  def delete_by_token(token) do
    with {:ok, raw} <- Base.url_decode64(token, padding: false) do
      delete_and_publish(from(s in UserSession, where: s.token_hash == ^hash(raw)))
    end

    :ok
  end

  @doc "Ends every idle or expired session; run by `QPBX.Core.SessionSweeper`."
  def sweep do
    now = now()
    idle_cutoff = DateTime.add(now, -idle_timeout())

    delete_and_publish(
      from(s in UserSession, where: s.last_seen_at < ^idle_cutoff or s.expires_at <= ^now)
    )
  end

  defp audited(actor, action, account, query) do
    {:ok, ids} =
      Repo.transaction(fn ->
        ids = delete_and_return(query)

        # Automatic revocations that ended nothing (e.g. first password) are not worth a log line.
        if ids != [] or not match?({:system, _}, actor),
          do:
            {:ok, _} = Repo.insert(Audit.entry(actor, action, account, %{sessions: length(ids)}))

        ids
      end)

    publish(ids)
    {:ok, length(ids)}
  end

  defp delete_and_publish(query), do: query |> delete_and_return() |> publish() |> length()

  defp delete_and_return(query) do
    {_, rows} = Repo.delete_all(select(query, [s], s.id))
    rows
  end

  defp publish([]), do: []

  defp publish(ids) do
    Events.publish(%SessionsRevoked{session_ids: ids, at: DateTime.utc_now()})
    ids
  end

  defp load(%UserSession{account_type: "platform_admin", account_id: id}),
    do: Repo.get(PlatformAdmin, id)

  defp load(%UserSession{account_type: "user", account_id: id}),
    do: User |> Repo.get(id) |> Repo.preload([:user_role, :tenant])

  defp type(%PlatformAdmin{}), do: "platform_admin"
  defp type(%User{}), do: "user"
  defp hash(raw), do: :crypto.hash(:sha256, raw)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
