defmodule EdgeOsCloud.Device.Edge do
  use Ecto.Schema
  import Ecto.Changeset

  schema "edges" do
    field :ip, :string
    field :name, :string
    field :status, :boolean
    field :deleted, :boolean, default: false

    timestamps()
  end

  @doc false
  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:name, :ip, :status, :deleted])
    |> validate_required([:name, :ip, :status])
  end
end
