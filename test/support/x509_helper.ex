defmodule X509Helper do
  @moduledoc "Builds a self-signed PEM certificate valid for `days` days (tests only)."
  use Boundary, top_level?: true, check: [in: false, out: false]

  def self_signed(days) do
    key = :public_key.generate_key({:rsa, 2048, 65_537})

    cert =
      :public_key.pkix_test_root_cert(~c"qpbx-test", [
        {:key, key},
        {:digest, :sha256},
        {:validity, validity(days)}
      ])

    :public_key.pem_encode([{:Certificate, cert[:cert], :not_encrypted}])
  end

  # public_key takes {From, To} as {Y, M, D} dates (13:00 UTC on each day).
  defp validity(days) do
    today = Date.utc_today()
    {Date.to_erl(Date.add(today, -1)), Date.to_erl(Date.add(today, days))}
  end
end
