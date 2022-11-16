defmodule EdgeOsCloud.Repo.Migrations.CreateEdges do
  use Ecto.Migration

  def change do
    create table(:edges) do
      add :name, :string
      add :ip, :string
      add :status, :string

      timestamps()
    end
  end
end
