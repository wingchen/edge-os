defmodule EdgeOsCloud.Accounts.Team do
  use Ecto.Schema
  import Ecto.Changeset

  schema "teams" do
    field :admins, {:array, :integer}
    field :name, :string
    field :members, {:array, :integer}
    field :deleted, :boolean, default: false

    timestamps()
  end

  @doc false
  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :admins, :members, :deleted])
    |> validate_required([:name, :admins, :members])
  end
end
