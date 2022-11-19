defmodule EdgeOsCloud.Repo.Migrations.CreateTeams do
  use Ecto.Migration

  def change do
    create table(:teams) do
      add :name, :string
      add :admins, {:array, :integer}

      timestamps()
    end
  end
end
