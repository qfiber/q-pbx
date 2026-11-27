defmodule QPBX.Storage do
  @moduledoc """
  Public API of the storage area: files (voicemail, recordings, faxes, prompts) encrypted at
  rest through a `QPBX.Storage.Backend` (local disk in v1, S3 later). Each file has its own
  random data key (AES-256-GCM); the data key is wrapped by the master key (`QPBX.Core.Vault`)
  and kept in the file's header, so a file key (its path) is all a table stores.
  See `lib/qpbx/storage/README.md`.
  """
  use Boundary, deps: [QPBX.Core], exports: []

  alias QPBX.Core.Vault

  @magic "QPS1"
  @areas ~w(voicemail recordings faxes prompts)
  @key_format ~r/\A(voicemail|recordings|faxes|prompts)\/\d{4}\/\d{2}\/[0-9a-f-]{36}\z/

  @doc "Encrypts and stores `plain`; returns the file key."
  def put(area, plain) when area in @areas and is_binary(plain) do
    %Date{year: y, month: m} = Date.utc_today()
    key = Path.join([area, "#{y}", pad(m), Ecto.UUID.generate()])
    data_key = :crypto.strong_rand_bytes(32)
    iv = :crypto.strong_rand_bytes(12)
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, data_key, iv, plain, @magic, true)
    wrapped = Vault.encrypt!(data_key)
    blob = [@magic, <<byte_size(wrapped)::16>>, wrapped, iv, tag, cipher]

    case backend().write(key, blob) do
      :ok -> {:ok, key}
      error -> error
    end
  end

  @doc "The decrypted contents of a stored file."
  def get(key) do
    with :ok <- valid_key(key),
         {:ok, blob} <- backend().read(key) do
      decrypt(blob)
    end
  end

  @doc """
  Decrypts a stored file into the private temporary folder (for FreeSWITCH to play) and returns
  its path; the caller deletes it when done (`discard/1`).
  """
  # sobelow_skip ["Traversal.FileModule"]
  # The path is ours: the configured folder and a fresh UUID (extension: a stored format).
  def decrypt_to_temp(key, extension) do
    with {:ok, plain} <- get(key) do
      path = Path.join(temp_dir(), "#{Ecto.UUID.generate()}.#{extension}")
      File.mkdir_p!(temp_dir())
      File.write!(path, plain)
      {:ok, path}
    end
  end

  @doc "Removes a temporary plain file (never one outside the temporary folder)."
  # sobelow_skip ["Traversal.FileModule"]
  def discard(path) do
    if Path.dirname(Path.expand(path)) == Path.expand(temp_dir()), do: File.rm(path)
    :ok
  end

  def delete(key) do
    with :ok <- valid_key(key), do: backend().delete(key)
  end

  @doc "Where plain media lives briefly (tmpfs on servers, shared with FreeSWITCH)."
  def temp_dir, do: config(:temp_dir)

  defp decrypt(
         <<@magic, len::16, wrapped::binary-size(len), iv::binary-12, tag::binary-16,
           cipher::binary>>
       ) do
    data_key = Vault.decrypt!(wrapped)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, data_key, iv, cipher, @magic, tag, false) do
      :error -> {:error, :corrupt}
      plain -> {:ok, plain}
    end
  end

  defp decrypt(_), do: {:error, :corrupt}

  # Keys are ours (area/year/month/uuid); anything else is refused, so no path escapes the root.
  defp valid_key(key) do
    if is_binary(key) and Regex.match?(@key_format, key),
      do: :ok,
      else: {:error, :bad_key}
  end

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")
  defp backend, do: config(:backend)
  defp config(k), do: Application.fetch_env!(:qpbx, __MODULE__) |> Keyword.fetch!(k)
end
