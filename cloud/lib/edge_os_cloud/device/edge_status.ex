defmodule EdgeOsCloud.Device.EdgeStatus do
  use Ecto.Schema
  import Ecto.Changeset

  schema "edge_statuss" do
    field :disk, {:array, :map}
    field :network, {:array, :map}
    field :temperature, {:array, :map}
    field :cpu, {:array, :map}
    field :gpu, :map
    field :memory, :map
    field :process_count, :integer
    
    belongs_to :edge, EdgeOsCloud.Device.Edge

    timestamps()
  end

  @doc false
  def changeset(edge_status, attrs) do
    edge_status
    |> cast(attrs, [:edge_id, :disk, :network, :temperature, :cpu, :memory, :process_count, :gpu])
    |> validate_required([:edge_id, :disk, :network, :temperature, :cpu, :memory, :process_count])
  end

  def to_map(edge_status) do
    %{
      disk: edge_status.disk, 
      network: edge_status.network, 
      temperature: edge_status.temperature, 
      cpu: edge_status.cpu, 
      gpu: edge_status.gpu, 
      memory: edge_status.memory, 
      process_count: edge_status.process_count, 
      edge_id: edge_status.edge_id
    }
  end
end
