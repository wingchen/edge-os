defmodule EdgeOsCloud.Device.EdgeCustomMetrics do
  use Ecto.Schema
  import Ecto.Changeset

  schema "edge_custom_metrics" do
    field :data, :map
    belongs_to :edge, EdgeOsCloud.Device.Edge

    timestamps()
  end

  @doc false
  def changeset(edge_status, attrs) do
    edge_status
    |> cast(attrs, [:edge_id, :data])
    |> validate_required([:edge_id, :data])
  end
end
