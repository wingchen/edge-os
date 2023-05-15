defmodule :"Elixir.EdgeOsCloud.Repo.Migrations.Record-gpu-usage" do
  use Ecto.Migration

  def change do
    alter table(:edge_statuss) do
      add :gpu, :map, default: nil
    end
  end
end
