defmodule QPBX.Core.KeyProviderTest do
  use ExUnit.Case, async: false
  alias QPBX.Core.KeyProvider

  @key :crypto.strong_rand_bytes(32)

  setup do
    old = Application.get_env(:qpbx, KeyProvider)
    on_exit(fn -> Application.put_env(:qpbx, KeyProvider, old) end)
    System.put_env("AWS_ACCESS_KEY_ID", "AKIDTEST")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")
    :ok
  end

  test "local source decodes a 32-byte base64 key and refuses anything else" do
    Application.put_env(:qpbx, KeyProvider, source: :local, key: Base.encode64(@key))
    assert KeyProvider.master_key() == @key
    Application.put_env(:qpbx, KeyProvider, source: :local, key: Base.encode64("short"))
    assert_raise RuntimeError, ~r/32 bytes/, &KeyProvider.master_key/0
  end

  test "AWS KMS: unwraps the stored blob with a signed Decrypt bound to Q-PBX" do
    dir = System.tmp_dir!() |> Path.join("kms-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    blob_file = Path.join(dir, "master-key.kms")
    File.write!(blob_file, "QkxPQg==\n")

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-amz-target") == ["TrentService.Decrypt"]
      assert [auth] = Plug.Conn.get_req_header(conn, "authorization")

      assert auth =~ "AWS4-HMAC-SHA256 Credential=AKIDTEST/" and
               auth =~ "/eu-central-1/kms/aws4_request"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert body["CiphertextBlob"] == "QkxPQg=="
      assert body["EncryptionContext"] == %{"app" => "q-pbx", "purpose" => "cloak-master-key"}
      Req.Test.json(conn, %{"Plaintext" => Base.encode64(@key)})
    end)

    Application.put_env(:qpbx, KeyProvider,
      source: :aws_kms,
      region: "eu-central-1",
      key_id: "alias/qpbx",
      blob_file: blob_file,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )

    assert KeyProvider.master_key() == @key
  end

  test "AWS KMS: a refusal stops start-up with a clear error" do
    dir = System.tmp_dir!() |> Path.join("kms-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "b"), "QkxPQg==")

    Req.Test.stub(
      __MODULE__,
      &Plug.Conn.send_resp(&1, 400, ~s({"__type":"AccessDeniedException"}))
    )

    Application.put_env(:qpbx, KeyProvider,
      source: :aws_kms,
      region: "eu-central-1",
      key_id: "k",
      blob_file: Path.join(dir, "b"),
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )

    assert_raise RuntimeError, ~r/could not unwrap/, &KeyProvider.master_key/0
  end

  test "wrap sends Encrypt with the key and the same context" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-amz-target") == ["TrentService.Encrypt"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert Base.decode64!(body["Plaintext"]) == @key
      assert body["EncryptionContext"]["purpose"] == "cloak-master-key"
      Req.Test.json(conn, %{"CiphertextBlob" => "V1JBUFBFRA=="})
    end)

    assert {:ok, "V1JBUFBFRA=="} =
             KeyProvider.wrap(@key,
               region: "eu-central-1",
               key_id: "k",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end
end
