defmodule QPBX.Web.Health.Checks do
  @moduledoc """
  One function per component. Each returns `{status, detail}` with status `:ok`, `:warning`,
  `:error` or `:not_configured`, and must finish quickly (the runner also enforces a timeout).
  """
  import Ecto.Query

  @doc "PostgreSQL answers a trivial query."
  def postgres(_opts) do
    case Ecto.Adapters.SQL.query(QPBX.Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> {:ok, "reachable"}
      {:error, e} -> {:error, Exception.message(e)}
    end
  end

  @doc "Free space on each configured path; warning under `:warn_percent` free, error under `:error_percent`."
  def disk(opts) do
    paths = Keyword.get(opts, :paths, ["/"])
    warn = Keyword.get(opts, :warn_percent, 15)
    err = Keyword.get(opts, :error_percent, 5)

    results =
      Enum.map(paths, fn path ->
        case free_percent(path) do
          {:ok, free} when free < err -> {:error, "#{path}: #{free}% free"}
          {:ok, free} when free < warn -> {:warning, "#{path}: #{free}% free"}
          {:ok, free} -> {:ok, "#{path}: #{free}% free"}
          {:error, why} -> {:error, "#{path}: #{why}"}
        end
      end)

    {worst(Enum.map(results, &elem(&1, 0))), Enum.map_join(results, ", ", &elem(&1, 1))}
  end

  @doc false
  def free_percent(path) do
    case System.cmd("df", ["-P", "-k", path], stderr_to_stdout: true) do
      {out, 0} -> parse_df(out)
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  def parse_df(out) do
    with [_header, line | _] <- String.split(out, "\n", trim: true),
         [_fs, total, _used, avail | _] <- String.split(line),
         {total, ""} when total > 0 <- Integer.parse(total),
         {avail, ""} <- Integer.parse(avail) do
      {:ok, div(avail * 100, total)}
    else
      _ -> {:error, "cannot parse df output"}
    end
  end

  @doc "Jobs waiting to run; warning over `:warn`, error over `:error`."
  def oban_backlog(opts) do
    warn = Keyword.get(opts, :warn, 1_000)
    err = Keyword.get(opts, :error, 10_000)
    now = DateTime.utc_now()

    count =
      QPBX.Repo.aggregate(
        from(j in Oban.Job,
          where: j.state in ["available", "scheduled"] and j.scheduled_at <= ^now
        ),
        :count,
        timeout: 2_000
      )

    status =
      cond do
        count >= err -> :error
        count >= warn -> :warning
        true -> :ok
      end

    {status, "#{count} waiting"}
  end

  @doc "Days until the TLS certificate at `:path` expires; warning under `:warn_days`."
  def certificate(opts) do
    case Keyword.get(opts, :path) do
      nil -> {:not_configured, "no certificate path"}
      path -> cert_status(path, Keyword.get(opts, :warn_days, 14))
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The path comes from the operator's configuration, never from a request.
  defp cert_status(path, warn_days) do
    with {:ok, pem} <- File.read(path),
         [{:Certificate, der, _} | _] <- :public_key.pem_decode(pem),
         {:ok, not_after} <- not_after(der) do
      days = DateTime.diff(not_after, DateTime.utc_now(), :day)

      cond do
        days < 0 -> {:error, "expired #{-days} days ago"}
        days < warn_days -> {:warning, "expires in #{days} days"}
        true -> {:ok, "expires in #{days} days"}
      end
    else
      {:error, reason} -> {:error, "cannot read #{path}: #{inspect(reason)}"}
      _ -> {:error, "no certificate in #{path}"}
    end
  end

  @doc false
  def not_after(der) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    {:Validity, _from, to} = elem(tbs, 5)
    {:ok, parse_asn1_time(to)}
  rescue
    _ -> {:error, :bad_certificate}
  end

  defp parse_asn1_time({:utcTime, t}), do: parse_asn1_time({:generalTime, ~c"20" ++ t})

  defp parse_asn1_time({:generalTime, t}) do
    <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, "Z">> =
      to_string(t)

    [y, mo, d, h, mi, s] = Enum.map([y, mo, d, h, mi, s], &String.to_integer/1)
    DateTime.new!(Date.new!(y, mo, d), Time.new!(h, mi, s))
  end

  @doc "FreeSWITCH event socket accepts a TCP connection (full ESL login arrives in phase 2)."
  def freeswitch(opts) do
    case Keyword.get(opts, :event_socket) do
      nil -> {:not_configured, "event socket not configured"}
      {host, port} -> tcp(host, port)
    end
  end

  @doc "Kamailio answers `core.version` over JSON-RPC (xhttp on localhost)."
  def kamailio(opts) do
    case Keyword.get(opts, :jsonrpc_url) do
      nil ->
        {:not_configured, "JSON-RPC URL not configured"}

      url ->
        body = %{jsonrpc: "2.0", method: "core.version", id: 1}

        case Req.post(url, json: body, receive_timeout: 2_000, retry: false) do
          {:ok, %{status: 200, body: %{"result" => _}}} -> {:ok, "answering"}
          {:ok, resp} -> {:error, "unexpected answer (HTTP #{resp.status})"}
          {:error, e} -> {:error, Exception.message(e)}
        end
    end
  end

  @doc "Trunk registrations are managed by Kamailio from phase 2."
  def trunk_registrations(_opts), do: {:not_configured, "no trunks before phase 2"}

  defp tcp(host, port) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:ok, "#{host}:#{port} reachable"}

      {:error, reason} ->
        {:error, "#{host}:#{port} #{:inet.format_error(reason)}"}
    end
  end

  @order [:ok, :not_configured, :warning, :error]
  @doc "The worst of several statuses."
  def worst([]), do: :ok
  def worst(statuses), do: Enum.max_by(statuses, &Enum.find_index(@order, fn s -> s == &1 end))
end
