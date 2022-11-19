defmodule EdgeOsCloud.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `EdgeOsCloud.Accounts` context.
  """

  @doc """
  Generate a user.
  """
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "some email",
        name: "some name"
      })
      |> EdgeOsCloud.Accounts.create_user()

    user
  end

  @doc """
  Generate a team.
  """
  def team_fixture(attrs \\ %{}) do
    {:ok, team} =
      attrs
      |> Enum.into(%{
        admins: [],
        name: "some name"
      })
      |> EdgeOsCloud.Accounts.create_team()

    team
  end
end
