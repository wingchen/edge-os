defmodule EdgeOsCloud.Device.Edge do
  use Ecto.Schema
  import Ecto.Changeset

  schema "edges" do
    field :ip, :string
    field :name, :string
    field :status, :string

    timestamps()
  end

  @doc false
  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:name, :ip, :status])
    |> validate_required([:name, :ip, :status])
  end
end
