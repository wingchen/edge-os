defmodule EdgeOsCloud.Device.EdgeStatus do
  use Ecto.Schema
  import Ecto.Changeset

  schema "edge_statuss" do
    field :disk, {:array, :map}
    field :network, {:array, :map}
    field :temperature, {:array, :map}
    field :cpu, {:array, :map}
    field :memory, :map
    field :process_count, :integer
    
    belongs_to :edge, EdgeOsCloud.Device.Edge

    timestamps()
  end

  @doc false
  def changeset(edge_status, attrs) do
    edge_status
    |> cast(attrs, [:edge_id, :disk, :network, :temperature, :cpu, :memory, :process_count])
    |> validate_required([:edge_id, :disk, :network, :temperature, :cpu, :memory, :process_count])
  end
end
