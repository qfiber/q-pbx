defmodule QPBX.Repo.Migrations.PlanAdmissionLimits do
  use Ecto.Migration

  # Call admission (2-6): concurrent calls per extension, and outbound minutes per destination
  # class per hour, day and month. Empty = unlimited, like every plan limit.
  def change do
    alter table(:plans) do
      add :max_concurrent_calls_per_extension, :integer

      for class <- ~w(local mobile international premium), period <- ~w(hour day month) do
        add :"minutes_#{class}_per_#{period}", :integer
      end
    end
  end
end
