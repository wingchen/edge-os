defmodule EdgeOsCloud.Device.EdgeStatus do
  use Ecto.Schema

  embedded_schema do
    field :disks, :map
    field :cpu, :map
    field :memory, :map

    field :battery_life, :integer
    field :on_ac_power, :boolean
    field :load_average_fifteen, :integer    
    field :uptime, :integer
    field :boot_time, :integer

    field :socket_stats, :integer
  end
end
