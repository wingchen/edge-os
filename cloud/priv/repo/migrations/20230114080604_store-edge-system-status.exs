defmodule :"Elixir.EdgeOsCloud.Repo.Migrations.Store-edge-system-status" do
  use Ecto.Migration

  def change do
    alter table(:edges) do
      add :edge_info, :map, default: %{}
    end

    create table(:edge_statuss) do
      add :disk, {:array, :map}, default: []
      add :network, {:array, :map}, default: []
      add :temperature, {:array, :map}, default: []
      add :cpu, {:array, :map}, default: []
      add :memory, :map, default: %{}
      add :process_count, :integer, default: 0
      
      add :edge_id, references(:edges, on_delete: :nothing)

      timestamps()
    end
  end
end
