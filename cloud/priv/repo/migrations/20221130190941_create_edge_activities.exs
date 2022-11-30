defmodule EdgeOsCloud.Repo.Migrations.CreateEdgeActivities do
  use Ecto.Migration

  def change do
    create table(:edge_activities) do
      add :activity, :string
      add :meta, :string
      add :edge_id, references(:edges, on_delete: :nothing)

      timestamps()
    end

    create index(:edge_activities, [:edge_id])
  end
end
