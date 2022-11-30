defmodule EdgeOsCloud.Device.Edge do
  use Ecto.Schema
  import Ecto.Changeset

  schema "edges" do
    field :ip, :string
    field :name, :string
    field :status, :boolean
    field :deleted, :boolean, default: false
    belongs_to :team, EdgeOsCloud.Accounts.Team

    # the salt for edge to encrypt edge_session ids
    field :salt, :string

    # the uuid is used by edge to indentiy itself
    field :uuid, :string

    # the password generated from edge when it's first created
    field :password, :string

    timestamps()
  end

  @doc false
  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:name, :ip, :status, :deleted, :team_id, :salt, :password, :uuid])
    |> validate_required([:name, :ip, :status, :team_id, :salt, :password, :uuid])
  end
end
