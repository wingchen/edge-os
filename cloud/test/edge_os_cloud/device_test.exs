defmodule EdgeOsCloud.DeviceTest do
  use EdgeOsCloud.DataCase

  import EdgeOsCloud.AccountsFixtures
  import EdgeOsCloud.DeviceFixtures
  alias EdgeOsCloud.Device
  alias EdgeOsCloud.Device.EdgeStatus

  def get_test_package() do
    user = user_fixture()
    team = team_fixture(user)
    edge = edge_fixture(team)

    [user, team, edge]
  end

  describe "create_edge_status" do
    test "inserts item in if payload is correct" do
      [_user, _team, edge] = get_test_package()

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

  describe "recent_edge_alerts_from_edges" do
    test "when the there are not supposed to be any alert, we do not see any alert" do
      [_user, _team, edge] = get_test_package()
      edge_status = edge_status_fixture(edge)
      cached_id = Device.edge_status_cache_key(edge.id)
      Device.cache_recent_edge_status(edge.id, Jason.encode!(EdgeStatus.to_map(edge_status)))

      assert [] = Device.recent_edge_alerts_from_edges([edge])
    end

    test "when we see a high CPU situation, we should get the alert" do
      [_user, _team, edge] = get_test_package()
      cached_id = Device.edge_status_cache_key(edge.id)

      edge_status = edge_status_fixture(edge, %{cpu: [%{name: "cpu0", usage: 86}, %{name: "cpu1", usage: 90}]})
      Device.cache_recent_edge_status(edge.id, Jason.encode!(EdgeStatus.to_map(edge_status)))
      assert ["Edge some name has high CPU usage!"] = Device.recent_edge_alerts_from_edges([edge])

      # the the new CPUs are coming down, we do not alert
      edge_status_1 = edge_status_fixture(edge, %{cpu: [%{name: "cpu0", usage: 70}, %{name: "cpu1", usage: 90}]})
      Device.cache_recent_edge_status(edge.id, Jason.encode!(EdgeStatus.to_map(edge_status_1)))
      assert [] = Device.recent_edge_alerts_from_edges([edge])
    end

    test "when we see a high memory situation, we should get alert" do
      [_user, _team, edge] = get_test_package()
      cached_id = Device.edge_status_cache_key(edge.id)

      edge_status = edge_status_fixture(edge, %{memory: %{used_swap: 20, total_swap: 1073, used_memory: 3600, total_memory: 3974}})
      Device.cache_recent_edge_status(edge.id, Jason.encode!(EdgeStatus.to_map(edge_status)))
      assert ["Edge some name has high memory usage!"] = Device.recent_edge_alerts_from_edges([edge])

      # the the new memories are coming down, we do not alert
      edge_status = edge_status_fixture(edge, %{memory: %{used_swap: 20, total_swap: 1073, used_memory: 1500, total_memory: 3974}})
      Device.cache_recent_edge_status(edge.id, Jason.encode!(EdgeStatus.to_map(edge_status)))
      assert [] = Device.recent_edge_alerts_from_edges([edge])
    end

    test "when we see high disk situations, we should get them" do
      [_user, _team, edge] = get_test_package()
      cached_id = Device.edge_status_cache_key(edge.id)

      # when any of the disk is filled up, alert out
      edge_status = edge_status_fixture(edge, %{disk: [%{name: "/dev/mmcblk0p2", total: 15017.631744, available: 100.214272, removable: false}, %{name: "/dev/mmcblk0p1", total: 264.28928, available: 96.818176, removable: false}]})
      Device.cache_recent_edge_status(edge.id, Jason.encode!(EdgeStatus.to_map(edge_status)))
      assert ["Edge some name has high disk usage at /dev/mmcblk0p2!"] = Device.recent_edge_alerts_from_edges([edge])

      # the alert is still there until all clears out
      edge_status = edge_status_fixture(edge, %{disk: [%{name: "/dev/mmcblk0p2", total: 15017.631744, available: 11017.214272, removable: false}, %{name: "/dev/mmcblk0p1", total: 264.28928, available: 96.818176, removable: false}]})
      Device.cache_recent_edge_status(edge.id, Jason.encode!(EdgeStatus.to_map(edge_status)))
      assert ["Edge some name has high disk usage at /dev/mmcblk0p2!"] = Device.recent_edge_alerts_from_edges([edge])
    end

    test "when we see more than 1 type of situations, we should get all of them" do
      [_user, _team, edge] = get_test_package()
      cached_id = Device.edge_status_cache_key(edge.id)

      edge_status = edge_status_fixture(edge, %{
        memory: %{used_swap: 20, total_swap: 1073, used_memory: 3600, total_memory: 3974},
        disk: [%{name: "/dev/mmcblk0p2", total: 15017.631744, available: 100.214272, removable: false}, %{name: "/dev/mmcblk0p1", total: 264.28928, available: 96.818176, removable: false}],
        cpu: [%{name: "cpu0", usage: 86}, %{name: "cpu1", usage: 90}]
      })

      Device.cache_recent_edge_status(edge.id, Jason.encode!(EdgeStatus.to_map(edge_status)))
      assert [
        "Edge some name has high CPU usage!", 
        "Edge some name has high memory usage!", 
        "Edge some name has high disk usage at /dev/mmcblk0p2!"
        ] = Device.recent_edge_alerts_from_edges([edge])
    end
  end
end
