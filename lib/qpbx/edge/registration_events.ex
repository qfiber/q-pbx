defmodule QPBX.Edge.RegistrationEvents do
  @moduledoc """
  Kamailio reports a device login's registration changes (a new contact, a removal, an
  expiry) to the app; this turns each report into `QPBX.Events.ExtensionRegistration`. A
  device login is `<extension>` or `<extension>-<label>`, so its extension is the part before
  the first dash.
  """
  alias QPBX.Core
  alias QPBX.Events
  alias QPBX.Events.ExtensionRegistration

  @kinds %{
    "registered" => {"registered", nil},
    "unregistered" => {"unregistered", "unregister"},
    "expired" => {"unregistered", "expired"}
  }

  @doc "Publishes the event for a report: `:ok`, or `{:error, :unknown}` (no such extension or bad report)."
  def report(%{"event" => event, "aor" => aor} = params)
      when is_map_key(@kinds, event) and is_binary(aor) do
    {type, reason} = @kinds[event]

    with [device, domain] <- String.split(aor, "@", parts: 2),
         [number | _] <- String.split(device, "-", parts: 2),
         %{} = ext <- Core.extension_at(String.downcase(domain), number) do
      Events.publish(%ExtensionRegistration{
        type: type,
        reason: reason,
        tenant_id: ext.tenant_id,
        extension_id: ext.extension_id,
        extension: ext.number,
        device: device,
        contact: text(params["contact"]),
        user_agent: params |> Map.get("ua_hex") |> unhex() |> text(),
        at: DateTime.utc_now()
      })
    else
      _ -> {:error, :unknown}
    end
  end

  def report(_), do: {:error, :unknown}

  # Kamailio sends the user agent hex-encoded, so nothing a phone sends there breaks the JSON.
  defp unhex(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, text} -> if String.valid?(text), do: text
      :error -> nil
    end
  end

  defp unhex(_), do: nil

  defp text(v) when is_binary(v) and v != "", do: String.slice(v, 0, 200)
  defp text(_), do: nil
end
