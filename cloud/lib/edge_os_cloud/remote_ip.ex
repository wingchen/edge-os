defmodule EdgeOsCloud.RemoteIp do
  require Logger

  def get(conn) do
    forwarded_for = List.first(Plug.Conn.get_req_header(conn, "x-forwarded-for"))

    if forwarded_for do
      String.split(forwarded_for, ",")
      |> Enum.map(&String.trim/1)
      |> List.first()
    else
      to_string(:inet_parse.ntoa(conn.remote_ip))
    end
  end

  def get_from_peer(peer) do
    if peer do
      case peer do
        {{one, two, three, four}, port} -> "#{one}.#{two}.#{three}.#{four}:#{port}"
        others ->
          Logger.warning("cannot get remote ip address from websocket connection: #{inspect others}")
          "wrong format: #{inspect others}"
      end
    else
      "none"
    end 
  end
end
