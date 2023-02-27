defmodule EdgeOsCloud.Device.EdgeSession do
  use Ecto.Schema
  import Ecto.Changeset

  schema "edge_sessions" do
    belongs_to :edge, EdgeOsCloud.Device.Edge
    belongs_to :user, EdgeOsCloud.Accounts.User
    field :reason, :string
    field :host, :string
    field :port, :integer
    field :actions, {:array, :integer}

    timestamps()
  end

  @doc false
  def changeset(edge_session, attrs) do
    edge_session
    |> cast(attrs, [:edge_id, :user_id, :actions, :reason, :host, :port])
    |> validate_required([:edge_id, :user_id, :host, :port])
  end
end

defmodule EdgeOsCloud.Device.EdgeSessionStage do
  @value %{
    created: 0,
    edge_connected: 1,
    user_connected: 2,
    tcp_data_get: 3,
    tcp_data_sent: 4,
    tcp_disconnected: 5,
    edge_disconnected: 6,
    user_disconnected: 7
  }

  @inverted Enum.reduce(@value, %{}, fn {key, value}, acc ->
    Map.put(acc, value, key)
  end)

  def get() do
    @value
  end

  def get_invert() do
    @inverted
  end
end
