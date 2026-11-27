defmodule QPBX.Core.Tenant do
  @moduledoc "A company with its own SIP domain under the platform's base domain."
  use Ecto.Schema
  import Ecto.Changeset
  alias QPBX.Core.Plan

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :sip_domain, :string
    field :timezone, :string
    field :locale, :string, default: "en"
    field :limit_overrides, :map, default: %{}
    belongs_to :plan, Plan
    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs, base_domain) do
    tenant
    |> cast(attrs, [:name, :slug, :timezone, :locale, :plan_id, :limit_overrides])
    |> validate_required([:name, :slug, :timezone, :locale, :plan_id])
    |> validate_length(:name, max: 200)
    # A single DNS label: it becomes <slug>.<base_domain>.
    |> validate_format(:slug, ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/,
      message: "lowercase letters, digits and dashes, not starting or ending with a dash"
    )
    |> validate_inclusion(:locale, QPBX.Core.locales())
    |> validate_change(:timezone, &validate_timezone/2)
    |> validate_change(:limit_overrides, &validate_overrides/2)
    |> slug_fixed_after_creation()
    |> put_sip_domain(base_domain)
    |> foreign_key_constraint(:plan_id)
    |> unique_constraint(:slug)
    |> unique_constraint(:sip_domain)
  end

  # The SIP domain is part of every stored digest hash (HA1); changing it would lock every phone out.
  defp slug_fixed_after_creation(%Ecto.Changeset{data: %{id: id}} = cs) when not is_nil(id) do
    if Ecto.Changeset.get_change(cs, :slug),
      do: add_error(cs, :slug, "cannot change after the tenant is created"),
      else: cs
  end

  defp slug_fixed_after_creation(cs), do: cs

  defp put_sip_domain(cs, base_domain) do
    case get_change(cs, :slug) do
      nil -> cs
      slug -> put_change(cs, :sip_domain, "#{slug}.#{base_domain}")
    end
  end

  defp validate_timezone(:timezone, tz) do
    case DateTime.now(tz) do
      {:ok, _} -> []
      {:error, _} -> [timezone: "is not a known time zone"]
    end
  end

  defp validate_overrides(:limit_overrides, overrides) do
    known = Enum.map(Plan.limits(), &Atom.to_string/1)

    Enum.flat_map(overrides, fn {k, v} ->
      cond do
        to_string(k) not in known ->
          [limit_overrides: "unknown limit #{k}"]

        not (is_nil(v) or (is_integer(v) and v >= 0)) ->
          [limit_overrides: "#{k} must be a non-negative integer or null"]

        true ->
          []
      end
    end)
  end
end
