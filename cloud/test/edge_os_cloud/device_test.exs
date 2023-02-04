defmodule EdgeOsCloud.DeviceTest do
  use EdgeOsCloud.DataCase

  import EdgeOsCloud.AccountsFixtures
  import EdgeOsCloud.DeviceFixtures
  alias EdgeOsCloud.Device

  describe "create_edge_status" do
    test "inserts item in if payload is correct" do
      user = user_fixture()
      team = team_fixture(user)
      edge = edge_fixture(team)

      test_payload = %{
        edge_id: edge.id, 
        cpu: [%{"name" => "cpu0", "usage" => 100.0}, %{"name" => "cpu1", "usage" => 75.0}, %{"name" => "cpu2", "usage" => 85.71429}, %{"name" => "cpu3", "usage" => 75.0}], 
        disk: [%{"available" => 2599.718912, "name" => "/dev/mmcblk0p1", "removable" => false, "total" => 29458.731008}, %{"available" => 65.982976, "name" => "/dev/mmcblk0p40", "removable" => false, "total" => 66.059264}], 
        memory: %{"total_memory" => 32517.607424, "total_swap" => 16258.793472, "used_memory" => 1089.585152, "used_swap" => 0.0}, 
        network: [%{"name" => "eth1", "received" => 0.083, "transmitted" => 0.07}, %{"name" => "usb0", "received" => 0.0, "transmitted" => 0.0}, %{"name" => "docker0", "received" => 0.0, "transmitted" => 0.0}, %{"name" => "l4tbr0", "received" => 0.0, "transmitted" => 0.0}, %{"name" => "dummy0", "received" => 0.0, "transmitted" => 0.0}, %{"name" => "lo", "received" => 0.0, "transmitted" => 0.0}, %{"name" => "eth0", "received" => 0.0, "transmitted" => 0.0}, %{"name" => "rndis0", "received" => 0.0, "transmitted" => 0.0}], 
        process_count: 279, 
        temperature: [%{"label" => "2490000ethernet00 temp1", "temperature" => 36.0}, %{"label" => "thermal_fan_est temp1", "temperature" => 30.5}]
      }

      assert {:ok, _} = Device.create_edge_status(test_payload)
    end
  end
end
