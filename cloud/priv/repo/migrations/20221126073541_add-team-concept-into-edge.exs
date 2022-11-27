defmodule :"Elixir.EdgeOsCloud.Repo.Migrations.Add-team-concept-into-edge" do
  use Ecto.Migration

  def change do
    alter table(:edges) do
      add :team, references(:teams, on_delete: :nothing)
    end

    create index(:edges, [:team])
  end
end
