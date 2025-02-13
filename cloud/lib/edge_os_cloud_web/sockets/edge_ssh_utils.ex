defmodule EdgeOsCloud.Sockets.EdgeSSHUtils do
  require Logger

  alias EdgeOsCloud.Device

  def get_topic(edge_id) do
    "et_edge_id_#{edge_id}_to_edge"
  end

  def create_ssh_connection(user, edge, user_ip) do
    websocket_pid_atom = String.to_atom(get_topic(edge.id))

    case Process.whereis(websocket_pid_atom) do
      nil ->
        {:error, "cannot find the pid for websocket process for edge #{inspect websocket_pid_atom}"}

      websocket_pid ->
        ssh_port = EdgeOsCloud.Sockets.TCPPortSelector.get_port()

        if is_nil(ssh_port) do
          Logger.error("no available port found for ssh session on edge #{edge.id}")
          {:error, "EdgeOS server has resource constraint. Please contact the maintainer."}
        else
          # tell the edge to connect in for ssh bridging
          {:ok, session} = Device.create_edge_session(%{
            edge_id: edge.id,
            user_id: user.id,
            host: "127.0.0.1",
            port: ssh_port,
          })

          cmd = "SSH #{Device.get_session_id_hash(edge, session.id)}"
          Logger.info("commading to edge #{edge.id} with command #{cmd}")
          send(websocket_pid, cmd)

          # start a cloud ssh server to handle bridging
          # we need to use an async task because UserTcpSocket init is blocking until an user connects in
          Task.start(fn ->
            EdgeOsCloud.Sockets.UserTcpSocket.start_link(session_port: ssh_port, session_id: session.id, user_ip: user_ip)
          end)

          {:ok, session, "sending message to #{edge.name}"}
        end
    end
  end

  def is_session_ready(session_id) do
    user_process_ready = case Process.whereis(EdgeOsCloud.Sockets.UserTcpSocket.get_pid(session_id)) do
      nil -> false
      _user_pid -> true
    end
    
    edge_process_ready = case Process.whereis(EdgeOsCloud.Sockets.EdgeTcpSocket.get_pid(session_id)) do
      nil -> false
      _user_pid -> true
    end

    user_process_ready and edge_process_ready
  end
end
