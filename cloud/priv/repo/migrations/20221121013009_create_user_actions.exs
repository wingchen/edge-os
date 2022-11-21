defmodule EdgeOsCloud.Repo.Migrations.CreateUserAction do
  use Ecto.Migration

  def change do
    create table(:user_actions) do
      add :action, :string
      add :meta, :string
      add :user, references(:users, on_delete: :nothing)

      timestamps()
    end

    create index(:user_actions, [:user])
  end
end
