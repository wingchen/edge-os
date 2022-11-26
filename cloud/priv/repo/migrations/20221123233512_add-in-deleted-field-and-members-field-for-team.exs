defmodule :"Elixir.EdgeOsCloud.Repo.Migrations.Add-in-deleted-field-and-members-field-for-team" do
  use Ecto.Migration

  def change do
    alter table(:teams) do
      add :deleted, :boolean, default: false
      add :members, {:array, :integer}
    end
  end
end
