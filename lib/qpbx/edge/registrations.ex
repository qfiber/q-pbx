defmodule QPBX.Edge.Registrations do
  @moduledoc """
  Keeps Kamailio's remote registrations (uac) equal to the enabled registration trunks. The
  password is decrypted only here and sent over the localhost JSON-RPC socket, never stored in
  a database view. Kamailio registers as the trunk id (`l_uuid`), so a carrier's INVITE to
  that user identifies the trunk. Runs on every trunk change and every minute, which also
  restores the records after a Kamailio restart.
  """
  alias QPBX.Core
  alias QPBX.Core.Trunk
  alias QPBX.Edge

  @expires 300

  @doc "Adds, replaces and removes records until Kamailio matches the database."
  def sync do
    if Edge.config()[:jsonrpc_url], do: reconcile(), else: :ok
  end

  defp reconcile do
    with {:ok, dump} <- Edge.rpc("uac.reg_dump") do
      current = Map.new(List.wrap(dump), &{&1["l_uuid"], &1})
      desired = Map.new(Core.registration_trunks(), &{&1.id, record(&1)})
      adds = for {id, rec} <- desired, not same?(current[id], rec), do: add(rec)

      removes =
        for id <- Map.keys(current),
            not Map.has_key?(desired, id),
            do: Edge.rpc("uac.reg_remove", [id])

      case Enum.reject(adds ++ removes, &match?({:ok, _}, &1)) do
        [] -> :ok
        errors -> {:error, errors}
      end
    end
  end

  @doc "The uac record for a trunk; the first address (lowest priority) is the registrar."
  def record(%Trunk{} = t) do
    [first | _] = Enum.sort_by(t.addresses, & &1.priority)
    host = if String.contains?(first.host, ":"), do: "[#{first.host}]", else: first.host
    transport = if first.transport == "udp", do: "", else: ";transport=#{first.transport}"

    %{
      "l_uuid" => t.id,
      "l_username" => t.id,
      "l_domain" => Core.sip_base_domain(),
      "r_username" => t.username,
      "r_domain" => first.host,
      "auth_username" => t.username,
      "auth_password" => t.password,
      "auth_proxy" => "sip:#{host}:#{first.port}#{transport}",
      "expires" => @expires
    }
  end

  defp add(rec) do
    params = [
      rec["l_uuid"],
      rec["l_username"],
      rec["l_domain"],
      rec["r_username"],
      rec["r_domain"],
      ".",
      rec["auth_username"],
      rec["auth_password"],
      ".",
      rec["auth_proxy"],
      rec["expires"],
      0,
      0,
      ".",
      "."
    ]

    Edge.rpc("uac.reg_add", params)
  end

  # Kamailio's dump has the same keys; a record differs if any of ours does.
  defp same?(nil, _rec), do: false

  defp same?(current, rec),
    do: Enum.all?(rec, fn {k, v} -> to_string(current[k]) == to_string(v) end)
end
