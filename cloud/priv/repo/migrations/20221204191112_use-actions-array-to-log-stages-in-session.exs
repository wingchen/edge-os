defmodule :"Elixir.EdgeOsCloud.Repo.Migrations.Use-actions-array-to-log-stages-in-session" do
  use Ecto.Migration

  def change do
    alter table(:edge_sessions) do
      remove :stage
      add :actions, {:array, :integer}
    end
  end
end
