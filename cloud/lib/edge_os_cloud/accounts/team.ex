defmodule EdgeOsCloud.Accounts.Team do
  use Ecto.Schema
  import Ecto.Changeset

  schema "teams" do
    field :admins, {:array, :integer}
    field :name, :string

    timestamps()
  end

  @doc false
  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :admins])
    |> validate_required([:name, :admins])
  end
end
