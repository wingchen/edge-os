defmodule EdgeOsCloud.DeviceFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `EdgeOsCloud.Device` context.
  """

  @doc """
  Generate a edge.
  """
  def edge_fixture(team, attrs \\ %{}) do
    {:ok, edge} =
      attrs
      |> Enum.into(%{
        team_id: team.id,
        ip: "some ip",
        name: "some name",
        status: true,
        salt: "some salt",
        password: "some password",
        uuid: "some uuid"
      })
      |> EdgeOsCloud.Device.create_edge()

    edge
  end

  @doc """
  Generate a session.
  """
  def session_fixture(attrs \\ %{}) do
    {:ok, session} =
      attrs
      |> Enum.into(%{

      })
      |> EdgeOsCloud.Device.create_session()

    session
  end
end
