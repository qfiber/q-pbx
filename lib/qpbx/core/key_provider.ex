defmodule QPBX.Core.KeyProvider do
  @moduledoc """
  Where the Cloak master key comes from (`config :qpbx, QPBX.Core.KeyProvider`):

    * `source: :local`: base64 key in `QPBX_CLOAK_KEY` (from the root-only secrets file).
    * `source: :aws_kms`: the key is kept on the server only wrapped by AWS KMS
      (`blob_file`); at start-up it is unwrapped with KMS `Decrypt`, so the plain key never
      rests on disk. KMS logs every unwrap and access can be revoked there.
      Options: `region`, `key_id`, `blob_file`, optional `endpoint` (a KMS-compatible test
      server); credentials from `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`.

  The key is bound to Q-PBX with a KMS encryption context, so the wrapped blob cannot be
  unwrapped for another purpose without that context.
  """

  @context %{"app" => "q-pbx", "purpose" => "cloak-master-key"}

  @doc "The 32-byte master key."
  def master_key do
    case config()[:source] || :local do
      :local -> config()[:key] |> decode!()
      :aws_kms -> unwrap!(config())
    end
  end

  @doc "Wraps `plaintext` with KMS `Encrypt`; returns the base64 blob to store on the server."
  def wrap(plaintext, opts) when byte_size(plaintext) == 32 do
    body = %{
      "KeyId" => opts[:key_id],
      "Plaintext" => Base.encode64(plaintext),
      "EncryptionContext" => @context
    }

    case kms(opts, "Encrypt", body) do
      {:ok, %{"CiphertextBlob" => blob}} -> {:ok, blob}
      error -> error
    end
  end

  defp unwrap!(opts) do
    blob = opts[:blob_file] |> File.read!() |> String.trim()
    body = %{"CiphertextBlob" => blob, "KeyId" => opts[:key_id], "EncryptionContext" => @context}

    case kms(opts, "Decrypt", body) do
      {:ok, %{"Plaintext" => plain}} -> decode!(plain)
      {:error, reason} -> raise "AWS KMS could not unwrap the master key: #{inspect(reason)}"
    end
  end

  defp kms(opts, action, body) do
    region = opts[:region] || raise "KMS region missing"
    url = opts[:endpoint] || "https://kms.#{region}.amazonaws.com/"

    [
      url: url,
      headers: [
        {"x-amz-target", "TrentService." <> action},
        {"content-type", "application/x-amz-json-1.1"}
      ],
      body: Jason.encode!(body),
      aws_sigv4: [
        service: "kms",
        region: region,
        access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
        secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
        token: System.get_env("AWS_SESSION_TOKEN")
      ],
      receive_timeout: 10_000,
      retry: :transient
    ]
    |> Keyword.merge(opts[:req_options] || [])
    |> Req.post()
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, decode_json(body)}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, e} -> {:error, e}
    end
  end

  defp decode_json(body) when is_binary(body), do: Jason.decode!(body)
  defp decode_json(body), do: body

  defp decode!(nil), do: raise("master key missing (QPBX_CLOAK_KEY)")

  defp decode!(b64) do
    case Base.decode64(b64) do
      {:ok, key} when byte_size(key) == 32 -> key
      _ -> raise "master key must be 32 bytes, base64-encoded"
    end
  end

  defp config, do: Application.get_env(:qpbx, __MODULE__, [])
end
