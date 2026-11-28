defmodule QPBX.Integrations.OutboundHTTP do
  @moduledoc """
  The one HTTP client for addresses a tenant chooses (webhooks, alert webhooks, CRM URLs):

  - HTTPS only, always; no credentials in the URL.
  - The host is resolved here and every answer must be a public address
    (`QPBX.Integrations.Address`); one inside answer refuses the request (no DNS-rebinding
    mix). The connection then goes to the checked address itself, with the original name for
    the Host header, SNI and certificate verification, so the name is never resolved twice.
  - Redirects (up to `max_redirects`) go through all of it again; 303, and 301/302 after a
    POST, continue as GET without a body; `authorization` is dropped when the host changes.
  - Limits: `connect_timeout`, `timeout` for the whole exchange redirects included,
    `max_body` for the response.

  Installation settings (`config :qpbx, QPBX.Integrations`): `allow_cidrs` (inside networks
  the operator trusts, such as a lab receiver; default none) and `ca_file` (a PEM file of
  extra certificate authorities trusted next to the system's, such as a lab CA; default none).
  Emits `[:qpbx, :outbound, :request]` telemetry (`duration`; `host`, `result`).
  """
  alias QPBX.Integrations.Address

  @defaults [timeout: 10_000, connect_timeout: 5_000, max_body: 1_000_000, max_redirects: 3]
  @redirects [301, 302, 303, 307, 308]

  @type response :: %{status: integer(), headers: [{String.t(), String.t()}], body: binary()}

  @doc """
  Sends a request: `{:ok, %{status, headers, body}}` for any HTTP status, or `{:error,
  reason}`: `:bad_url`, `:https_required`, `{:blocked_address, ip}`, `:nxdomain`, `:timeout`,
  `:too_large`, `:too_many_redirects`, `{:connect, reason}`, `{:http, reason}`.
  Options: `headers`, `body`, the limits above, and (tests) `resolver`, `cacerts`.
  """
  @spec request(atom() | String.t(), String.t(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(method, url, opts \\ []) do
    opts =
      @defaults
      |> Keyword.merge(Application.get_env(:qpbx, QPBX.Integrations, []))
      |> Keyword.merge(opts)

    started = System.monotonic_time()
    deadline = System.monotonic_time(:millisecond) + opts[:timeout]
    method = method |> to_string() |> String.upcase()
    headers = [{"user-agent", "Q-PBX"} | opts[:headers] || []]
    result = follow(method, url, headers, opts[:body], opts, deadline, 0)

    :telemetry.execute(
      [:qpbx, :outbound, :request],
      %{duration: System.monotonic_time() - started},
      %{
        host: host_of(url),
        result: outcome(result)
      }
    )

    result
  end

  defp follow(method, url, headers, body, opts, deadline, hops) do
    with {:ok, uri} <- check_url(url),
         {:ok, ip} <- resolve(uri.host, opts, deadline),
         {:ok, resp} <- send_once(method, uri, ip, headers, body, opts, deadline) do
      max = opts[:max_redirects]

      case location(resp, uri) do
        nil -> {:ok, resp}
        _ when hops >= max -> {:error, :too_many_redirects}
        next -> redirect(resp.status, uri, next, {method, headers, body}, opts, deadline, hops)
      end
    end
  end

  # 303, and 301/302 after a POST, continue as GET without a body; authorization stays with
  # its host.
  defp redirect(status, uri, next, {method, headers, body}, opts, deadline, hops) do
    {method, body} =
      if status == 303 or (status in [301, 302] and method == "POST"),
        do: {"GET", nil},
        else: {method, body}

    headers =
      if next.host == uri.host,
        do: headers,
        else: Enum.reject(headers, fn {k, _} -> String.downcase(k) == "authorization" end)

    follow(method, URI.to_string(next), headers, body, opts, deadline, hops + 1)
  end

  defp check_url(url) do
    case URI.new(url) do
      {:ok, %URI{host: host, userinfo: nil, scheme: scheme} = uri}
      when is_binary(host) and host != "" ->
        case scheme do
          "https" -> {:ok, uri}
          "http" -> {:error, :https_required}
          _ -> {:error, :bad_url}
        end

      _ ->
        {:error, :bad_url}
    end
  end

  # Every address the name has must be allowed; the first one is used.
  defp resolve(host, opts, deadline) do
    case lookup(host, opts, deadline) do
      {:ok, []} ->
        {:error, :nxdomain}

      {:ok, [first | _] = ips} ->
        case Enum.reject(ips, &Address.allowed?(&1, opts[:allow_cidrs] || [])) do
          [] -> {:ok, first}
          [bad | _] -> {:error, {:blocked_address, bad |> :inet.ntoa() |> to_string()}}
        end

      error ->
        error
    end
  end

  defp lookup(host, opts, deadline) do
    resolver = opts[:resolver]

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, [ip]}
      {:error, _} when is_function(resolver, 1) -> {:ok, resolver.(host)}
      {:error, _} -> dns(host, deadline)
    end
  end

  # Both families, within what is left of the time limit.
  defp dns(host, deadline) do
    name = String.to_charlist(host)

    task =
      Task.async(fn ->
        for family <- [:inet, :inet6],
            {:ok, ips} <- [:inet.getaddrs(name, family)],
            ip <- ips,
            do: ip
      end)

    case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
      {:ok, ips} -> {:ok, ips}
      _ -> {:error, :timeout}
    end
  end

  defp send_once(method, uri, ip, headers, body, opts, deadline) do
    case Mint.HTTP.connect(:https, ip, uri.port, connect_opts(uri, opts, deadline)) do
      {:ok, conn} ->
        {result, conn} = split(exchange(conn, method, uri, headers, body, opts, deadline))
        Mint.HTTP.close(conn)
        result

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  # To the checked address, with the name for Host, SNI and certificate verification.
  defp connect_opts(uri, opts, deadline) do
    cacerts = opts[:cacerts] || :public_key.cacerts_get() ++ extra_cacerts(opts[:ca_file])

    [
      hostname: uri.host,
      protocols: [:http1],
      mode: :passive,
      transport_opts: [
        timeout: min(opts[:connect_timeout], remaining(deadline)),
        verify: :verify_peer,
        cacerts: cacerts,
        depth: 5
      ]
    ]
  end

  # The installation's own certificate authorities (a PEM file), next to the system's.
  defp extra_cacerts(nil), do: []
  defp extra_cacerts(""), do: []

  # sobelow_skip ["Traversal.FileModule"]
  # The path is the installation's setting (server environment), never from a request.
  defp extra_cacerts(path) do
    case File.read(path) do
      {:ok, pem} -> for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der
      {:error, _} -> []
    end
  end

  defp exchange(conn, method, uri, headers, body, opts, deadline) do
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    case Mint.HTTP.request(conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        receive_response(conn, ref, %{status: nil, headers: [], body: []}, 0, opts, deadline)

      {:error, conn, reason} ->
        {:error, {:http, reason}, conn}
    end
  end

  defp split({:ok, resp, conn}), do: {{:ok, resp}, conn}
  defp split({:error, reason, conn}), do: {{:error, reason}, conn}

  defp receive_response(conn, ref, acc, size, opts, deadline) do
    case remaining(deadline) do
      0 -> {:error, :timeout, conn}
      wait -> conn |> Mint.HTTP.recv(0, wait) |> received(ref, acc, size, opts, deadline)
    end
  end

  defp received({:ok, conn, parts}, ref, acc, size, opts, deadline) do
    case collect(parts, ref, acc, size, opts[:max_body]) do
      {:done, acc} -> {:ok, %{acc | body: IO.iodata_to_binary(Enum.reverse(acc.body))}, conn}
      {:more, acc, size} -> receive_response(conn, ref, acc, size, opts, deadline)
      :too_large -> {:error, :too_large, conn}
    end
  end

  defp received({:error, conn, %{reason: :timeout}, _}, _, _, _, _, _),
    do: {:error, :timeout, conn}

  defp received({:error, conn, reason, _}, _, _, _, _, _), do: {:error, {:http, reason}, conn}

  defp collect([], _ref, acc, size, _max), do: {:more, acc, size}

  defp collect([{:status, ref, s} | rest], ref, acc, size, max),
    do: collect(rest, ref, %{acc | status: s}, size, max)

  defp collect([{:headers, ref, h} | rest], ref, acc, size, max),
    do: collect(rest, ref, %{acc | headers: acc.headers ++ h}, size, max)

  defp collect([{:data, ref, d} | rest], ref, acc, size, max) do
    size = size + byte_size(d)

    if size > max,
      do: :too_large,
      else: collect(rest, ref, %{acc | body: [d | acc.body]}, size, max)
  end

  defp collect([{:done, ref} | _], ref, acc, _size, _max), do: {:done, acc}
  defp collect([_ | rest], ref, acc, size, max), do: collect(rest, ref, acc, size, max)

  defp location(%{status: s, headers: h}, base) when s in @redirects do
    case List.keyfind(Enum.map(h, fn {k, v} -> {String.downcase(k), v} end), "location", 0) do
      {_, loc} -> URI.merge(base, loc)
      nil -> nil
    end
  end

  defp location(_, _), do: nil

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp host_of(url) do
    case URI.new(url) do
      {:ok, %{host: h}} -> h
      _ -> nil
    end
  end

  defp outcome({:ok, %{status: s}}), do: s
  defp outcome({:error, {reason, _}}), do: reason
  defp outcome({:error, reason}), do: reason
end
