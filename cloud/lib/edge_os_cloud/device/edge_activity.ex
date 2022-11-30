defmodule EdgeOsCloud.Device.EdgeActivity do
  use Ecto.Schema
  import Ecto.Changeset

  schema "edge_activities" do
    field :activity, :string
    field :meta, :string
    belongs_to :edge, EdgeOsCloud.Device.Edge

    timestamps()
  end

  @doc false
  def changeset(edge_activity, attrs) do
    edge_activity
    |> cast(attrs, [:activity, :edge_id, :meta])
    |> validate_required([:activity, :edge_id])
  end
end
