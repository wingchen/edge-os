defmodule EdgeOsCloud.Device.Edge do
  use Ecto.Schema
  import Ecto.Changeset

  schema "edges" do
    field :ip, :string
    field :name, :string
    field :status, :boolean
    field :deleted, :boolean, default: false
    belongs_to :team, EdgeOsCloud.Accounts.Team

    timestamps()
  end

  @doc false
  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:name, :ip, :status, :deleted, :team])
    |> validate_required([:name, :ip, :status, :team])
  end
end
