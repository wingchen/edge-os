defmodule EdgeOsCloud.DeviceFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `EdgeOsCloud.Device` context.
  """

  @doc """
  Generate an edge.
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
  Generate an edge_status.
  """
  def edge_status_fixture(edge, attrs \\ %{}) do
    {:ok, edge_status} =
      %{
        edge_id: edge.id,
        disk: [%{name: "/dev/mmcblk0p2", total: 15017.631744, available: 6996.214272, removable: false}, %{name: "/dev/mmcblk0p1", total: 264.28928, available: 96.818176, removable: false}],
        network: [%{name: "lo", received: 0.0, transmitted: 0.0}, %{name: "eth0", received: 0.06, transmitted: 0.0}],
        temperature: [%{label: "cpu_thermal temp1", temperature: 43.329}],
        cpu: [%{name: "cpu0", usage: 2}, %{name: "cpu1", usage: 2}, %{name: "cpu3", usage: 2}, %{name: "cpu2", usage: 2}],
        gpu: nil,
        memory: %{used_swap: 20.447232, total_swap: 1073.737728, used_memory: 907.730944, total_memory: 3974.20544},
        process_count: 300
      } 
      |> Map.merge(attrs)
      |> EdgeOsCloud.Device.create_edge_status()

    edge_status
  end
end
