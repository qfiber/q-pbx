defmodule QPBX.Core.ApiKey do
  @moduledoc """
  A key for the REST API: a tenant's (acts in that tenant) or the platform's (no tenant).
  Only a hash of the key is stored; it is shown once, when created.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @scopes ~w(read write calls fax admin)
  @expiry_days [30, 90, 365]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    field :name, :string
    field :prefix, :string
    field :token_hash, :binary, redact: true
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime
    # Form input: days until it expires, or "never".
    field :expires_in, :string, virtual: true, default: "90"
    belongs_to :tenant, QPBX.Core.Tenant
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def scopes, do: @scopes
  def expiry_days, do: @expiry_days

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:name, :scopes, :expires_in])
    |> update_change(:scopes, &Enum.reject(&1, fn s -> s in ["", nil] end))
    |> validate_required([:name])
    |> validate_length(:name, max: 100)
    |> then(
      &if(get_field(&1, :scopes) == [],
        do: add_error(&1, :scopes, "pick at least one scope"),
        else: &1
      )
    )
    |> validate_subset(:scopes, @scopes)
    |> validate_inclusion(:expires_in, ["never" | Enum.map(@expiry_days, &to_string/1)])
    |> put_expiry()
  end

  defp put_expiry(%{valid?: true} = cs) do
    case get_field(cs, :expires_in) do
      "never" ->
        cs

      days ->
        expires = DateTime.utc_now() |> DateTime.add(String.to_integer(days), :day)
        put_change(cs, :expires_at, DateTime.truncate(expires, :second))
    end
  end

  defp put_expiry(cs), do: cs

  @doc "True when the key has the scope."
  def allows?(%__MODULE__{scopes: scopes}, scope), do: scope in scopes

  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt
end
