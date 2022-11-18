defmodule :"Elixir.EdgeOsCloud.Repo.Migrations.Add-in-deleted-field-for-edge" do
  use Ecto.Migration

  def change do
    alter table(:edges) do
      add :deleted, :boolean, default: false
    end
  end
end
