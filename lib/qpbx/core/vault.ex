defmodule QPBX.Core.Vault do
  @moduledoc "Cloak vault for secrets at rest. The key comes from outside the database (`QPBX_CLOAK_KEY`)."
  use Cloak.Vault, otp_app: :qpbx
end

defmodule QPBX.Core.Encrypted.Binary do
  @moduledoc false
  use Cloak.Ecto.Binary, vault: QPBX.Core.Vault
end
