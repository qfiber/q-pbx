defmodule QPBX.Telephony.CdrImporter do
  @moduledoc """
  Imports FreeSWITCH's JSON CDR spool every 2 seconds, up to 500 files a round, in one batch,
  then deletes the imported files. Files younger than 2 seconds are left for the next round
  (FreeSWITCH may still be writing them). While the database is down nothing is deleted, so
  the spool is the queue: no CDR is lost while the app or Postgres is away. A file that is
  not valid JSON moves to `bad/` for a look by hand.
  """
  use GenServer
  require Logger
  alias QPBX.Telephony.{Cache, Cdrs}

  @every_ms 2_000
  @batch 500
  @min_age_s 2

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "One round now (tests and the lab check); returns how many rows were stored."
  def run(dir \\ spool()), do: import_dir(dir)

  @impl true
  def init(_) do
    Process.send_after(self(), :run, @every_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:run, s) do
    try do
      import_dir(spool())
    rescue
      e -> Logger.warning("cdr import: #{Exception.message(e)}; files kept for the next round")
    end

    Process.send_after(self(), :run, @every_ms)
    {:noreply, s}
  end

  # sobelow_skip ["Traversal.FileModule"]
  # Paths are the configured spool folder and the names FreeSWITCH gave its files.
  defp import_dir(dir) do
    now = System.os_time(:second)

    files =
      case File.ls(dir) do
        {:ok, names} -> for n <- names, String.ends_with?(n, ".cdr.json"), do: Path.join(dir, n)
        _ -> []
      end
      |> Enum.filter(fn p ->
        match?({:ok, %{mtime: m}} when now - m >= @min_age_s, File.stat(p, time: :posix))
      end)
      |> Enum.take(@batch)

    {rows, done} =
      Enum.reduce(files, {[], []}, fn path, {rows, done} ->
        case read(path, dir) do
          :bad -> {rows, done}
          :skip -> {rows, [path | done]}
          row -> {[row | rows], [path | done]}
        end
      end)

    rows = Enum.map(rows, &known_tenant/1)
    timezones = for %{tenant_id: t} <- rows, t != nil, into: %{}, do: {t, timezone(t)}
    n = Cdrs.insert_batch(rows, timezones)
    Enum.each(done, &File.rm/1)
    n
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path, dir) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      Cdrs.from_json(json)
    else
      _ ->
        File.mkdir_p!(Path.join(dir, "bad"))
        File.rename(path, Path.join([dir, "bad", Path.basename(path)]))
        :bad
    end
  end

  # A tenant deleted since the call (or never real): the row stays, without a tenant.
  defp known_tenant(%{tenant_id: nil} = r), do: r
  defp known_tenant(%{tenant_id: t} = r), do: if(timezone(t), do: r, else: %{r | tenant_id: nil})

  defp timezone(tid) do
    case Cache.tenant(tid) do
      %{tenant: %{timezone: tz}} -> tz
      _ -> nil
    end
  end

  defp spool, do: Application.get_env(:qpbx, QPBX.Telephony, [])[:cdr_spool]
end
