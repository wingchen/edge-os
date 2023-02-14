defmodule EdgeOsCloud.Repo.Migrations.DbTableForCustomMetrics do
  use Ecto.Migration

  def change do
    create table(:edge_custom_metrics) do
      add :data, :map, default: %{}      
      add :edge_id, references(:edges, on_delete: :nothing)

      timestamps()
    end
  end
end
