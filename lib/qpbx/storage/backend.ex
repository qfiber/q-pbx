defmodule QPBX.Storage.Backend do
  @moduledoc "Where encrypted files live. Keys are already validated by `QPBX.Storage`."
  @callback write(key :: String.t(), iodata()) :: :ok | {:error, term()}
  @callback read(key :: String.t()) :: {:ok, binary()} | {:error, term()}
  @callback delete(key :: String.t()) :: :ok | {:error, term()}
end
