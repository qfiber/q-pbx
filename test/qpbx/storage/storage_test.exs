defmodule QPBX.StorageTest do
  use ExUnit.Case, async: true
  alias QPBX.Storage

  test "a stored file is encrypted on disk and comes back whole; a damaged one is refused" do
    plain = :crypto.strong_rand_bytes(5000) <> "hello voicemail"
    {:ok, key} = Storage.put("voicemail", plain)
    assert key =~ ~r/\Avoicemail\/\d{4}\/\d{2}\//
    on_disk = File.read!(Path.join(Application.fetch_env!(:qpbx, Storage)[:root], key))
    refute on_disk =~ "hello voicemail"
    assert {:ok, ^plain} = Storage.get(key)

    <<head::binary-100, b, rest::binary>> = on_disk
    path = Path.join(Application.fetch_env!(:qpbx, Storage)[:root], key)
    File.write!(path, <<head::binary, Bitwise.bxor(b, 1), rest::binary>>)
    assert {:error, _} = Storage.get(key)

    assert :ok = Storage.delete(key)
    assert {:error, :enoent} = Storage.get(key)
  end

  test "keys that are not ours are refused (no path escapes the root)" do
    assert {:error, :bad_key} = Storage.get("../../etc/passwd")
    assert {:error, :bad_key} = Storage.delete("voicemail/2026/01/../../x")
  end

  test "a temporary plain copy, removed by discard; discard never touches other paths" do
    {:ok, key} = Storage.put("voicemail", "abc")
    {:ok, path} = Storage.decrypt_to_temp(key, "mp3")
    assert File.read!(path) == "abc"
    Storage.discard(path)
    refute File.exists?(path)
    outside = Path.join(System.tmp_dir!(), "qpbx-keep-#{System.unique_integer([:positive])}")
    File.write!(outside, "x")
    Storage.discard(outside)
    assert File.exists?(outside)
    File.rm!(outside)
  end
end
