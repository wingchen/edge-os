defmodule EdgeOsCloud.DeviceFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `EdgeOsCloud.Device` context.
  """

  @doc """
  Generate a edge.
  """
  def edge_fixture(attrs \\ %{}) do
    {:ok, edge} =
      attrs
      |> Enum.into(%{
        ip: "some ip",
        name: "some name",
        status: "some status"
      })
      |> EdgeOsCloud.Device.create_edge()

    edge
  end
end
