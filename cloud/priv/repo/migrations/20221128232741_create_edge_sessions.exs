defmodule EdgeOsCloud.Repo.Migrations.CreateEdgeSessions do
  use Ecto.Migration

  def change do
    create table(:edge_sessions) do
      add :edge_id, references(:edges, on_delete: :nothing)
      add :user_id, references(:users, on_delete: :nothing)
      add :stage, :integer, default: 0
      add :reason, :string
      add :host, :string
      add :port, :integer

      timestamps()
    end

    create index(:edge_sessions, [:edge_id])
    create index(:edge_sessions, [:user_id])

    alter table(:edges) do
      add :salt, :string
      add :password, :string
      add :uuid, :string
    end

    create index(:edges, [:uuid])
  end
end
