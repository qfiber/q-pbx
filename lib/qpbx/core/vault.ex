defmodule QPBX.Core.Vault do
  @moduledoc """
  Cloak vault for secrets at rest. Its master key comes from `QPBX.Core.KeyProvider` when the
  vault starts (local key or AWS KMS), never from compiled configuration.
  """
  use Cloak.Vault, otp_app: :qpbx

  @impl GenServer
  def init(config) do
    cipher =
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: QPBX.Core.KeyProvider.master_key(), iv_length: 12}

    {:ok, Keyword.put(config, :ciphers, default: cipher)}
  end
end

defmodule QPBX.Core.Encrypted.Binary do
  @moduledoc false
  use Cloak.Ecto.Binary, vault: QPBX.Core.Vault
end
