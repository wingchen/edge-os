defmodule :"Elixir.EdgeOsCloud.Repo.Migrations.Rename-team-field-to-team-id" do
  use Ecto.Migration

  def change do
    rename table(:edges), :team, to: :team_id
  end
end
