defmodule EdgeOsCloud.Sockets.TCPPortSelector do
  require Logger

  defp port_range() do
    {32800, 60990}
  end

  defp port_redis_key() do
    "edgeos_ports_in_use"
  end

  def get_port(depth \\ 0) do
    if depth < 3 do
      size = 20
      {port_candidate_start, port_candidate_end} = port_range()
      seed = :rand.uniform(port_candidate_end - port_candidate_start - size)
      candidates = Enum.to_list(seed..seed + size) |> Enum.map(fn x -> "#{x}" end)
      Logger.debug("tcp port candidates #{inspect candidates}")

      # see how many of the candidates are already taken
      cmd = [port_redis_key() | candidates]
      cmd = ["SMISMEMBER" | cmd]
      Logger.debug("checking the port candidacy with command #{inspect cmd}")
      {:ok, candidacy} = Redix.command(Redis, cmd)
      Logger.debug("port candidacy #{inspect candidacy}")

      qualified = Enum.zip(candidates, candidacy) |> Enum.filter(fn {_k, v} -> v == 0 end)
      Logger.debug("port candidacy qulification #{inspect qualified}")

      if Enum.count(qualified) == 0 do
        # all taken, try one more time
        get_port(depth + 1)
      else
        {selected, _} = Enum.random(qualified)
        String.to_integer(selected)
      end
    else
      Logger.error("no port is open after 3 attempts")
      nil
    end
  end

  def return_port(port) do
    cmds = [
      ["SREM", port_redis_key(), "#{port}"],
      ["SCARD", port_redis_key()],
    ]
    {:ok, [_, count]} = Redix.pipeline(Redis, cmds)
    Logger.debug("number of tcp ports still in use: #{count}")
  end
end
