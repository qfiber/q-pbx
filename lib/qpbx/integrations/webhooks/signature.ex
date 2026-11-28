defmodule QPBX.Integrations.Webhooks.Signature do
  @moduledoc """
  How deliveries are signed, and how a receiver checks them. Each request carries
  `x-qpbx-event-id`, `x-qpbx-timestamp` (Unix seconds) and
  `x-qpbx-signature: v1=<hex HMAC-SHA256 of "<timestamp>.<body>" with the endpoint's secret>`.
  A receiver recomputes it over the raw body, compares in constant time, and refuses old
  timestamps (5 minutes is a good limit) so a captured request cannot be replayed later.
  """

  def sign(secret, timestamp, body),
    do:
      "v1=" <>
        Base.encode16(:crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}"), case: :lower)

  @doc "True when `signature` matches and `timestamp` is within `tolerance` seconds of `now`."
  def valid?(secret, signature, timestamp, body, now \\ System.os_time(:second), tolerance \\ 300) do
    with {ts, ""} <- Integer.parse(to_string(timestamp)),
         true <- abs(now - ts) <= tolerance do
      Plug.Crypto.secure_compare(sign(secret, ts, body), signature)
    else
      _ -> false
    end
  end

  @doc "A new secret (`whsec_` and 32 random bytes)."
  def new_secret, do: "whsec_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
