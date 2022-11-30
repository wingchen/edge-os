defmodule EdgeOsCloud.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :key, :string
      add :value, :string

      timestamps()
    end

    create index(:settings, [:key])

    # generate a default salt for system ids
    EdgeOsCloud.System.get_setting("id_hash_salt")
  end
end
