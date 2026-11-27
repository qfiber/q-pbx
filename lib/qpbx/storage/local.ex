defmodule QPBX.Storage.Local do
  @moduledoc "Local disk backend: files under the configured root (`/var/lib/qpbx` on servers)."
  @behaviour QPBX.Storage.Backend

  # sobelow_skip ["Traversal.FileModule"]
  # Keys reach here only after QPBX.Storage validated them (area/yyyy/mm/uuid).
  @impl true
  def write(key, blob) do
    path = path(key)
    tmp = path <> ".part"

    # Written whole, then renamed: a crash never leaves half a file under its key.
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, blob, [:binary]) do
      File.rename(tmp, path)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def read(key), do: File.read(path(key))

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def delete(key) do
    case File.rm(path(key)) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  defp path(key), do: Path.join(Application.fetch_env!(:qpbx, QPBX.Storage)[:root], key)
end
