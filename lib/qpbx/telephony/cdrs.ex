defmodule QPBX.Telephony.Cdrs do
  @moduledoc """
  Call detail records. FreeSWITCH writes every leg as JSON into the spool (`mod_json_cdr`);
  `CdrImporter` turns batches of them into `cdrs` rows here and rolls a-legs up into
  `usage_daily`. The call process tags the a-leg (and, exported, its b-legs) with `qpbx_*`
  variables so a row shows the tenant, the direction and extension numbers rather than device
  logins; trunk legs carry their trunk.
  """
  import Ecto.Query
  alias QPBX.Core.Scope
  alias QPBX.Repo
  alias QPBX.Telephony.Cdr

  @directions ~w(inbound outbound internal)
  def directions, do: @directions

  ## From FreeSWITCH

  @doc """
  The applications that tag a call's a-leg for its CDR when it starts (`export` reaches the
  b-legs too): tenant, shown caller, dialed destination, direction (inbound from a carrier,
  else internal until a carrier is dialed).
  """
  def tags(call, tenant_id, caller) do
    direction = if call.source == :trunk, do: "inbound", else: "internal"

    [
      tenant_id && {"export", "qpbx_tenant=#{tenant_id}"},
      caller && {"export", "qpbx_caller=#{clean(caller)}"},
      {"set", "qpbx_destination=#{clean(call.destination)}"},
      {"export", "qpbx_direction=#{direction}"}
    ]
    |> Enum.filter(& &1)
  end

  # Values go into FreeSWITCH applications' arguments: nothing that could split them.
  defp clean(v), do: v |> to_string() |> String.replace(~r/[^\w+*#@.\-]/u, "")

  @doc """
  The row for one spooled leg (decoded JSON), or `:skip` for legs that are not calls of their
  own (the echo test's loopback channels).
  """
  def from_json(%{"variables" => v}) do
    v = Map.new(v, fn {k, val} -> {k, URI.decode(to_string(val))} end)

    # Loopback channels (the echo test) and anything without its ids are not calls of their own.
    if String.starts_with?(v["channel_name"] || "", "loopback/") or is_nil(uuid(v["uuid"])),
      do: :skip,
      else: row(v)
  end

  def from_json(_), do: :skip

  defp row(v) do
    leg = if v["direction"] == "outbound", do: "b", else: "a"
    now = DateTime.truncate(DateTime.utc_now(), :second)
    started = epoch(v["start_epoch"]) || now
    answered = epoch(v["answer_epoch"])
    billsec = int(v["billsec"])

    %{
      tenant_id: uuid(v["qpbx_tenant"] || v["sip_h_X-QPBX-Tenant"]),
      leg_uuid: v["uuid"],
      # A b-leg's own call_uuid is not its call's: the a-leg that placed it is.
      call_uuid: uuid(v["originating_leg_uuid"]) || uuid(v["call_uuid"]) || v["uuid"],
      leg: leg,
      direction: direction(v, leg),
      caller_number: pick(v, ~w(qpbx_caller caller_id_number origination_caller_id_number)),
      caller_name: pick(v, ~w(caller_id_name origination_caller_id_name)),
      destination: pick(v, ~w(qpbx_callee qpbx_destination destination_number dialed_user)),
      trunk_id: uuid(v["qpbx_trunk_id"] || if(leg == "a", do: v["sip_h_X-QPBX-Trunk"])),
      started_at: started,
      answered_at: answered,
      ended_at: epoch(v["end_epoch"]) || started,
      duration: int(v["duration"]),
      billsec: billsec,
      hangup_cause: v["hangup_cause"],
      disposition: disposition(answered, billsec, v["hangup_cause"])
    }
  end

  defp pick(v, keys), do: Enum.find_value(keys, &v[&1])

  defp direction(v, leg) do
    cond do
      v["qpbx_direction"] in @directions -> v["qpbx_direction"]
      leg == "a" and v["sip_h_X-QPBX-Source"] == "trunk" -> "inbound"
      true -> "internal"
    end
  end

  defp disposition(answered, billsec, cause) do
    cond do
      answered || billsec > 0 -> "answered"
      cause in ~w(USER_BUSY CALL_REJECTED) -> "busy"
      cause in ~w(NO_ANSWER NO_USER_RESPONSE ORIGINATOR_CANCEL ALLOTTED_TIMEOUT) -> "no_answer"
      true -> "failed"
    end
  end

  defp epoch(s) do
    case int(s) do
      0 -> nil
      n -> DateTime.from_unix!(n)
    end
  end

  defp int(nil), do: 0

  defp int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp uuid(nil), do: nil

  defp uuid(s) do
    case Ecto.UUID.cast(s) do
      {:ok, u} -> u
      :error -> nil
    end
  end

  @doc """
  Stores a batch (legs already stored are skipped, so a re-import is harmless) and rolls the new
  a-legs up into `usage_daily`. `timezones`: tenant id => time zone. Returns the number stored.
  """
  def insert_batch([], _timezones), do: 0

  def insert_batch(rows, timezones) do
    Repo.transaction(fn ->
      {n, inserted} =
        Repo.insert_all(Cdr, rows,
          on_conflict: :nothing,
          conflict_target: :leg_uuid,
          returning: [:tenant_id, :leg, :direction, :started_at, :billsec, :disposition]
        )

      for %{leg: "a", tenant_id: tid} = c <- inserted, tid != nil, do: roll_up(c, timezones[tid])

      n
    end)
    |> then(fn {:ok, n} -> n end)
  end

  defp roll_up(c, timezone) do
    answered = if c.disposition == "answered", do: 1, else: 0

    Repo.insert_all(
      "usage_daily",
      [
        %{
          tenant_id: Ecto.UUID.dump!(c.tenant_id),
          day: local_day(c.started_at, timezone),
          direction: c.direction,
          calls: 1,
          answered: answered,
          seconds: c.billsec
        }
      ],
      on_conflict: [inc: [calls: 1, answered: answered, seconds: c.billsec]],
      conflict_target: [:tenant_id, :day, :direction]
    )
  end

  defp local_day(at, nil), do: DateTime.to_date(at)

  defp local_day(at, tz) do
    case DateTime.shift_zone(at, tz) do
      {:ok, l} -> DateTime.to_date(l)
      _ -> DateTime.to_date(at)
    end
  end

  ## For tenant admins

  @doc """
  The tenant's legs, newest first. Filters (all optional): `from`, `to` (dates, the tenant's
  time zone), `number` (part of the caller or destination), `direction`, `disposition`, `leg`
  ("a" by default: one row per call; "all").
  """
  def search(%Scope{kind: :tenant, tenant_id: tid} = scope, filters, timezone, opts \\ []) do
    Scope.run(scope, fn -> Repo.all(query(tid, filters, timezone, opts)) end)
  end

  @doc "Runs `fun` with a stream of every matching leg (for CSV export), oldest first."
  def stream(%Scope{kind: :tenant, tenant_id: tid} = scope, filters, timezone, fun) do
    Scope.run(scope, fn ->
      q =
        query(tid, filters, timezone, [])
        |> exclude(:order_by)
        |> exclude(:limit)
        |> order_by(asc: :started_at)

      fun.(Repo.stream(q, max_rows: 500))
    end)
  end

  @doc "Daily totals: `[%{day, direction, calls, answered, seconds}]`, newest first."
  def usage_daily(%Scope{kind: :tenant, tenant_id: tid} = scope, days \\ 31) do
    since = Date.add(Date.utc_today(), -days)

    Scope.run(scope, fn ->
      Repo.all(
        from u in "usage_daily",
          where: u.tenant_id == type(^tid, :binary_id) and u.day >= ^since,
          order_by: [desc: u.day, asc: u.direction],
          select: %{
            day: u.day,
            direction: u.direction,
            calls: u.calls,
            answered: u.answered,
            seconds: u.seconds
          }
      )
    end)
  end

  defp query(tid, f, tz, opts) do
    q =
      from c in Cdr,
        where: c.tenant_id == ^tid,
        order_by: [desc: c.started_at],
        limit: ^Keyword.get(opts, :limit, 50),
        offset: ^Keyword.get(opts, :offset, 0)

    q = if f["leg"] == "all", do: q, else: where(q, [c], c.leg == "a")
    q = if d = date(f["from"]), do: where(q, [c], c.started_at >= ^day_start(d, tz)), else: q

    q =
      if d = date(f["to"]),
        do: where(q, [c], c.started_at < ^day_start(Date.add(d, 1), tz)),
        else: q

    q =
      if f["direction"] in @directions, do: where(q, [c], c.direction == ^f["direction"]), else: q

    q =
      if f["disposition"] in ~w(answered busy no_answer failed),
        do: where(q, [c], c.disposition == ^f["disposition"]),
        else: q

    case digits(f["number"]) do
      "" ->
        q

      n ->
        like = "%" <> n <> "%"
        where(q, [c], like(c.caller_number, ^like) or like(c.destination, ^like))
    end
  end

  # Only digits, + and *: never LIKE wildcards from the user.
  defp digits(nil), do: ""
  defp digits(s), do: String.replace(s, ~r/[^0-9+*]/, "")

  defp date(s) when is_binary(s) and s != "" do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp date(_), do: nil

  defp day_start(date, tz) do
    case DateTime.new(date, ~T[00:00:00], tz || "Etc/UTC") do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:gap, _, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
      _ -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end
end
