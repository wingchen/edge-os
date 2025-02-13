defmodule :"Elixir.EdgeOsCloud.Repo.Migrations.Add-in-user-api-tokens" do
  use Ecto.Migration

  def change do
    create table(:user_api_tokens) do
      add :token, :string
      add :user_id, references(:users, on_delete: :nothing)

      add :created_at, :naive_datetime, default: fragment("now()")
      add :expiration, :naive_datetime, default: fragment("now() + interval '3 week'")
    end

    create index(:user_api_tokens, [:token])
    create index(:user_api_tokens, [:user_id, :expiration])
  end
end
