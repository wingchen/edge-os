defmodule EdgeOsCloud.Device.EdgeSession do
  use Ecto.Schema
  import Ecto.Changeset

  schema "edge_sessions" do
    belongs_to :edge, EdgeOsCloud.Device.Edge
    belongs_to :user, EdgeOsCloud.Accounts.User
    field :stage, :integer
    field :reason, :string
    field :host, :string
    field :port, :integer

    timestamps()
  end

  @doc false
  def changeset(edge_session, attrs) do
    edge_session
    |> cast(attrs, [:edge_id, :user_id, :stage, :reason, :host, :port])
    |> validate_required([:edge_id, :user_id, :host, :port])
  end
end

defmodule EdgeOsCloud.Device.EdgeSessionStage do
  def created, do: 0
  def edge_connected, do: 1
  def user_connected, do: 2
  def ssh_data_get, do: 3
  def ssh_data_sent, do: 4
  def ssh_disconnected, do: 5
  def edge_disconnected, do: 6
end
