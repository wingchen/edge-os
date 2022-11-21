defmodule EdgeOsCloud.Accounts.UserAction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_actions" do
    field :action, :string
    field :meta, :string
    field :user, :id

    timestamps()
  end

  @doc false
  def changeset(user_actions, attrs) do
    user_actions
    |> cast(attrs, [:action, :meta])
    |> validate_required([:action, :meta])
  end
end
