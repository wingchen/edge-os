defmodule EdgeOsCloud.DeviceTest do
  use EdgeOsCloud.DataCase

  alias EdgeOsCloud.Device

  describe "edges" do
    alias EdgeOsCloud.Device.Edge

    import EdgeOsCloud.DeviceFixtures

    @invalid_attrs %{ip: nil, name: nil, status: nil}

    test "list_edges/0 returns all edges" do
      edge = edge_fixture()
      assert Device.list_edges() == [edge]
    end

    test "get_edge!/1 returns the edge with given id" do
      edge = edge_fixture()
      assert Device.get_edge!(edge.id) == edge
    end

    test "create_edge/1 with valid data creates a edge" do
      valid_attrs = %{ip: "some ip", name: "some name", status: "some status"}

      assert {:ok, %Edge{} = edge} = Device.create_edge(valid_attrs)
      assert edge.ip == "some ip"
      assert edge.name == "some name"
      assert edge.status == "some status"
    end

    test "create_edge/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Device.create_edge(@invalid_attrs)
    end

    test "update_edge/2 with valid data updates the edge" do
      edge = edge_fixture()
      update_attrs = %{ip: "some updated ip", name: "some updated name", status: "some updated status"}

      assert {:ok, %Edge{} = edge} = Device.update_edge(edge, update_attrs)
      assert edge.ip == "some updated ip"
      assert edge.name == "some updated name"
      assert edge.status == "some updated status"
    end

    test "update_edge/2 with invalid data returns error changeset" do
      edge = edge_fixture()
      assert {:error, %Ecto.Changeset{}} = Device.update_edge(edge, @invalid_attrs)
      assert edge == Device.get_edge!(edge.id)
    end

    test "delete_edge/1 deletes the edge" do
      edge = edge_fixture()
      assert {:ok, %Edge{}} = Device.delete_edge(edge)
      assert_raise Ecto.NoResultsError, fn -> Device.get_edge!(edge.id) end
    end

    test "change_edge/1 returns a edge changeset" do
      edge = edge_fixture()
      assert %Ecto.Changeset{} = Device.change_edge(edge)
    end
  end
end
