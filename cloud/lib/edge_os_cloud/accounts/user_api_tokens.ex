defmodule EdgeOsCloud.Accounts.UserAPITokens do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_api_tokens" do
    field :token, :string
    field :user_id, :integer

    field :created_at, :naive_datetime
    field :expiration, :naive_datetime
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:token, :user_id, :created_at, :expiration])
    |> validate_required([:token, :user_id])
  end
end
