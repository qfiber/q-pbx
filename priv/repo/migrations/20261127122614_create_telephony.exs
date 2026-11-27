defmodule QPBX.Repo.Migrations.CreateTelephony do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    create table(:extensions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :number, :string, null: false
      add :name, :string, null: false
      add :external_caller_id, :string
      add :dnd, :boolean, null: false, default: false
      add :call_waiting, :boolean, null: false, default: true
      add :forward_always, :string
      add :forward_busy, :string
      add :forward_no_answer, :string
      add :no_answer_seconds, :integer, null: false, default: 20
      add :follow_me_enabled, :boolean, null: false, default: false
      add :follow_me_numbers, {:array, :string}, null: false, default: []
      timestamps(type: :utc_datetime)
    end

    create unique_index(:extensions, [:tenant_id, :number])

    create table(:devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :extension_id, references(:extensions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sip_credential_id,
          references(:sip_credentials, type: :binary_id, on_delete: :restrict),
          null: false

      add :label, :string, null: false
      add :kind, :string, null: false
      add :mac, :string
      add :model, :string
      add :push_platform, :string
      add :push_token, :binary
      timestamps(type: :utc_datetime)
    end

    create index(:devices, [:extension_id])
    create unique_index(:devices, [:sip_credential_id])
    create unique_index(:devices, [:mac], where: "mac IS NOT NULL")

    # Platform trunks (carriers, shared) have no tenant; tenant trunks are bring-your-own-carrier.
    create table(:trunks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :name, :string, null: false
      add :auth_mode, :string, null: false
      add :username, :string
      add :password, :binary
      add :codecs, {:array, :string}, null: false, default: []
      add :fax_mode, :string, null: false, default: "t38"
      add :ecm, :boolean, null: false, default: true
      add :max_channels, :integer
      add :caller_id_mode, :string, null: false, default: "tenant_numbers"
      add :default_caller_id, :string
      add :enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create table(:trunk_addresses, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :trunk_id, references(:trunks, type: :binary_id, on_delete: :delete_all), null: false
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :host, :string, null: false
      add :port, :integer, null: false, default: 5060
      add :transport, :string, null: false, default: "udp"
      add :priority, :integer, null: false, default: 1
      add :weight, :integer, null: false, default: 1
      timestamps(type: :utc_datetime)
    end

    create index(:trunk_addresses, [:trunk_id])

    create table(:dids, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :number, :string, null: false
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nilify_all)
      add :trunk_id, references(:trunks, type: :binary_id, on_delete: :nilify_all)
      add :destination_type, :string
      add :destination_id, :binary_id
      add :destination_number, :string
      add :alias_of_id, references(:dids, type: :binary_id, on_delete: :delete_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:dids, [:number])
    create index(:dids, [:tenant_id])

    create table(:outbound_routes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :prefixes, {:array, :string}, null: false, default: []
      add :position, :integer, null: false, default: 0
      add :destination_class, :string, null: false
      add :strip_digits, :integer, null: false, default: 0
      add :add_prefix, :string, null: false, default: ""
      add :enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create index(:outbound_routes, [:tenant_id, :position])

    create table(:route_trunks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :route_id, references(:outbound_routes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :trunk_id, references(:trunks, type: :binary_id, on_delete: :restrict), null: false
      add :position, :integer, null: false, default: 0
    end

    create unique_index(:route_trunks, [:route_id, :trunk_id])

    # Platform: short emergency numbers and the trunk that always carries them.
    create table(:emergency_routes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :number, :string, null: false
      add :trunk_id, references(:trunks, type: :binary_id, on_delete: :restrict), null: false
      add :enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:emergency_routes, [:number])

    # Number formats: one platform default row (tenant_id NULL), optional override per tenant.
    create table(:number_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :country_code, :string, null: false
      add :national_prefix, :string, null: false, default: "0"
      add :international_prefixes, {:array, :string}, null: false, default: ["00"]
      add :area_code, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:number_rules, [:tenant_id], nulls_distinct: false)

    # Platform: destination classes by E.164 prefix (longest match wins).
    create table(:number_classes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :prefix, :string, null: false
      add :class, :string, null: false
      add :note, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:number_classes, [:prefix])

    for t <-
          ~w(extensions devices trunks trunk_addresses dids outbound_routes route_trunks number_rules),
        do: RLS.enable(t)
  end
end
